import AppKit
import Dispatch
import Observation

/// Retains Chromium pages and their state while background tabs leave the window.
@MainActor
@Observable
final class PaneHosts {
    @ObservationIgnored private var browsers: [PaneID: ChromiumPage] = [:]
    @ObservationIgnored private var coordinators: [PaneID: BrowserCoordinator] = [:]
    @ObservationIgnored private var uploadPanes: Set<PaneID> = []
    @ObservationIgnored private var pendingScroll: [PaneID: Double] = [:]
    @ObservationIgnored private var memorySource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var iconTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var iconCache = DomainIconCache<NSImage>()
    @ObservationIgnored private let iconStore = DomainIconStore()
    @ObservationIgnored private var pageURLs: [PaneID: URL] = [:]
    @ObservationIgnored private var capturing: Set<PaneID> = []
    private(set) var titles: [PaneID: String] = [:]
    private(set) var favicons: [PaneID: NSImage] = [:]
    private(set) var previews: [PaneID: NSImage] = [:]
    private(set) var canGoBack: [PaneID: Bool] = [:]
    private(set) var canGoForward: [PaneID: Bool] = [:]
    private(set) var lifecycle = TabLifecycleLedger()

    func browser(for pane: PaneID, workspace: Workspace) -> ChromiumPage {
        if let existing = browsers[pane] {
            lifecycle.touch(pane)
            return existing
        }
        let coordinator = BrowserCoordinator(pane: pane, workspace: workspace)
        let initialURL = address(from: workspace.surfaces.line(pane))
        let page = ChromiumPage(initialURL: initialURL)
        page.forcedDarkMode = workspace.builtIns.darkens(initialURL)
        page.delegate = coordinator
        coordinators[pane] = coordinator
        browsers[pane] = page
        lifecycle.register(pane)
        lifecycle.touch(pane)
        return page
    }

    func forget(keep: (PaneID) -> Bool, kinds: (PaneID) -> Kind, downloads: DownloadCenter) {
        let tracked = Set(browsers.keys).union(lifecycle.panes)
        for pane in tracked where !keep(pane) || kinds(pane) != .browser {
            removeBrowser(pane, downloads: downloads)
            lifecycle.close(pane)
            uploadPanes.remove(pane)
            pendingScroll.removeValue(forKey: pane)
            pageURLs.removeValue(forKey: pane)
            titles.removeValue(forKey: pane)
            favicons.removeValue(forKey: pane)
            previews.removeValue(forKey: pane)
            canGoBack.removeValue(forKey: pane)
            canGoForward.removeValue(forKey: pane)
        }
    }

    func existingBrowser(_ pane: PaneID) -> ChromiumPage? { browsers[pane] }
    func forEachBrowser(_ body: (ChromiumPage) -> Void) { browsers.values.forEach(body) }
    func touch(_ pane: PaneID) { lifecycle.touch(pane) }
    func recovery(for pane: PaneID) -> BrowserRecovery? { lifecycle.recoveries[pane] }

    func beginRecovery(_ pane: PaneID) -> BrowserRecovery? {
        guard let recovery = lifecycle.takeRecovery(pane) else { return nil }
        if recovery.scrollY > 0 { pendingScroll[pane] = recovery.scrollY }
        return recovery
    }

    func beginUpload(_ pane: PaneID) { uploadPanes.insert(pane) }
    func endUpload(_ pane: PaneID) { uploadPanes.remove(pane) }

    @discardableResult
    func focus(_ pane: PaneID) -> Bool {
        guard let page = browsers[pane], page.window != nil else { return false }
        page.focus()
        return true
    }

    func updatePage(_ page: ChromiumPage, pane: PaneID) {
        guard browsers[pane] === page else { return }
        if pageURLs[pane] != page.url {
            pageURLs[pane] = page.url
            previews.removeValue(forKey: pane)
            lifecycle.touch(pane)
        }
        let title = page.title ?? ""
        if titles[pane] != title { titles[pane] = title }
        if canGoBack[pane] != page.canGoBack { canGoBack[pane] = page.canGoBack }
        if canGoForward[pane] != page.canGoForward { canGoForward[pane] = page.canGoForward }
    }

    func capturePreviews() {
        for (pane, page) in browsers where page.window != nil { capture(page, pane: pane) }
    }

    func capture(_ page: ChromiumPage, pane: PaneID) {
        guard !capturing.contains(pane) else { return }
        capturing.insert(pane)
        let url = page.url
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self else { return }
            self.capturing.remove(pane)
            guard let page, self.browsers[pane] === page, page.url == url,
                  let image = page.snapshot() else { return }
            self.previews[pane] = image
        }
    }

    func syncFavicons(tabs: [Tab], surfaces: Surfaces, pinned: Set<String> = []) {
        var owners: [PaneID: String] = [:]
        for tab in tabs {
            let pane = tab.active
            let url = pageURLs[pane] ?? address(from: surfaces.line(pane))
            owners[pane] = DomainIconCache<NSImage>.domain(url)
        }
        for domain in iconCache.retain(owners, pinned: pinned) { iconTasks.removeValue(forKey: domain)?.cancel() }
        for domain in Set(owners.values).union(pinned) where !iconCache.contains(domain) {
            guard let data = iconStore.data(for: domain) else { continue }
            guard let image = NSImage(data: data) else { continue }
            _ = iconCache.restore(domain, value: image)
        }
        publishFavicons()
    }

    func storedIconData(for domain: String) -> Data? {
        iconStore.data(for: domain)
    }

    func rememberIcon(_ data: Data, for domain: String) {
        try? iconStore.write(data, for: domain)
        if let image = NSImage(data: data), !iconCache.contains(domain) {
            _ = iconCache.restore(domain, value: image)
        }
        publishFavicons()
    }

    func fetchIcon(for url: URL) async -> Data? {
        guard let domain = DomainIconCache<NSImage>.domain(url) else { return nil }
        if let data = iconStore.data(for: domain), NSImage(data: data) != nil { return data }
        guard let token = iconCache.begin(domain) else {
            if let image = iconCache.value(forDomain: domain), let data = pngData(image) { return data }
            return iconStore.data(for: domain)
        }
        let data = await Self.downloadIcon(for: url)
        _ = iconCache.complete(domain, token: token, value: data.flatMap(NSImage.init(data:)))
        iconTasks.removeValue(forKey: domain)
        if let data { try? iconStore.write(data, for: domain) }
        publishFavicons()
        return data
    }

    private static func downloadIcon(for pageURL: URL) async -> Data? {
        let html = await pageHTML(pageURL)
        var tried: Set<URL> = []
        for url in FaviconCandidates.urls(for: pageURL, html: html) where ["https", "http"].contains(url.scheme ?? "") && tried.insert(url).inserted {
            guard let data = await imageData(url), NSImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }

    private static func pageHTML(_ pageURL: URL) async -> String? {
        var request = URLRequest(url: pageURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 512_000 else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func imageData(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 1_048_576 else { return nil }
        return data
    }

    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func publishFavicons() {
        let images = iconCache.owners.keys.reduce(into: [PaneID: NSImage]()) { result, pane in
            result[pane] = iconCache.value(for: pane)
        }
        if images != favicons { favicons = images }
    }

    func loadFavicon(_ page: ChromiumPage, pane: PaneID, workspace: Workspace? = nil) {
        guard let pageURL = page.url, let domain = DomainIconCache<NSImage>.domain(pageURL),
              let token = iconCache.begin(domain) else { return }
        iconTasks[domain] = Task { [weak self, weak page, weak workspace] in
            let script = "Array.from(document.querySelectorAll('link[rel]')).filter(l => l.rel.split(/\\s+/).some(r => r === 'icon' || r === 'apple-touch-icon')).map(l => l.href).slice(0, 4)"
            let links = (try? await page?.evaluateJavaScript(script)) as? [String] ?? []
            var candidates = DomainIconCache<NSImage>.domain(page?.url) == domain ? links.compactMap(URL.init(string:)) : []
            if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { candidates.append(fallback) }
            var icon: NSImage?
            var iconData: Data?
            var tried: Set<URL> = []
            for url in candidates where ["https", "http"].contains(url.scheme ?? "") && tried.insert(url).inserted {
                guard !Task.isCancelled else { return }
                // Favicons are immutable enough to honor HTTP/URLCache semantics.
                // Bypassing the cache here duplicated network work on retries
                // and revisits before the persistent icon store was populated.
                let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count < 1_048_576, let image = NSImage(data: data) else { continue }
                icon = image
                iconData = data
                break
            }
            guard !Task.isCancelled, let self,
                  self.iconCache.complete(domain, token: token, value: icon) else { return }
            if let iconData {
                try? self.iconStore.write(iconData, for: domain)
                workspace?.savedSites.fillMissingIcon(iconData, domain: domain)
            }
            self.iconTasks.removeValue(forKey: domain)
            self.publishFavicons()
        }
    }

    func startMemoryPressureMonitoring(workspace: Workspace) {
        guard memorySource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memorySource = source
        source.setEventHandler { @MainActor [weak self, weak workspace] in
            guard let self, let workspace, let event = self.memorySource?.data else { return }
            let pressure: TabMemoryPressure = event.contains(.critical) ? .critical : .warning
            Task { @MainActor [weak self, weak workspace] in
                guard let self, let workspace else { return }
                await self.discardBackgroundTabs(pressure: pressure, workspace: workspace)
            }
        }
        source.resume()
    }

    func stopMemoryPressureMonitoring() {
        memorySource?.cancel()
        memorySource = nil
    }

    func handleWebContentTermination(_ page: ChromiumPage, pane: PaneID, workspace: Workspace) {
        guard browsers[pane] === page else { return }
        let url = page.url ?? pageURLs[pane] ?? address(from: workspace.surfaces.line(pane))
        lifecycle.suspend(pane, recovery: BrowserRecovery(
            cause: .webContentTerminated,
            url: url,
            scrollY: 0,
            occurredAt: Date()
        ))
        pageURLs[pane] = url
        removeBrowser(pane, downloads: workspace.downloads)
    }

    func restoreScrollIfNeeded(_ page: ChromiumPage, pane: PaneID) {
        guard let y = pendingScroll.removeValue(forKey: pane), y > 0 else { return }
        page.evaluateJavaScript("window.scrollTo(0, \(y))")
    }

    private func discardBackgroundTabs(pressure: TabMemoryPressure, workspace: Workspace) async {
        let goal = TabMemoryPolicy.discardCount(liveCount: browsers.count, pressure: pressure)
        guard goal > 0 else { return }
        let candidates = browsers.map { pane, page in
            var protections: TabDiscardProtection = []
            if pane == workspace.activePane { protections.insert(.active) }
            if uploadPanes.contains(pane) { protections.insert(.upload) }
            if workspace.downloads.hasActiveDownload(for: page) { protections.insert(.download) }
            return TabMemoryCandidate(pane: pane, lastUsed: lifecycle.lastUsed[pane] ?? .distantPast,
                                      protections: protections)
        }
        var discarded = 0
        for pane in TabMemoryPolicy.orderedDiscardCandidates(candidates) where discarded < goal {
            guard let page = browsers[pane], let probe = await discardProbe(page), probe.safe else { continue }
            // The probe suspends, so the tab may have become active, started a
            // transfer, or been replaced in the meantime.
            guard browsers[pane] === page, pane != workspace.activePane, !uploadPanes.contains(pane),
                  !workspace.downloads.hasActiveDownload(for: page) else { continue }
            let url = page.url ?? pageURLs[pane] ?? address(from: workspace.surfaces.line(pane))
            lifecycle.suspend(pane, recovery: BrowserRecovery(cause: .memoryPressure, url: url,
                                                               scrollY: probe.scrollY, occurredAt: Date()))
            pageURLs[pane] = url
            removeBrowser(pane, downloads: workspace.downloads)
            discarded += 1
        }
    }

    private func discardProbe(_ page: ChromiumPage) async -> BrowserDiscardProbe? {
        guard let value = try? await page.evaluateJavaScript(BrowserDiscardProbe.script) else { return nil }
        return BrowserDiscardProbe.decode(value)
    }

    private func removeBrowser(_ pane: PaneID, downloads: DownloadCenter) {
        guard let page = browsers.removeValue(forKey: pane) else {
            coordinators.removeValue(forKey: pane)
            return
        }
        // Cancel first while the client is still attached; the completion
        // callback can no longer reach DownloadCenter once we detach below.
        downloads.interruptDownloads(for: page)
        page.delegate = nil
        page.close()
        coordinators.removeValue(forKey: pane)
    }
}

@MainActor
final class BrowserCoordinator: ChromiumPageDelegate {
    let pane: PaneID
    weak var workspace: Workspace?
    private var lastURL: URL?

    init(pane: PaneID, workspace: Workspace) {
        self.pane = pane
        self.workspace = workspace
    }

    private func update(_ page: ChromiumPage) {
        guard let workspace else { return }
        let urlChanged = lastURL != page.url
        if urlChanged {
            lastURL = page.url
            workspace.assistance.committed(pane)
            workspace.builtIns.apply(to: page)
        }
        workspace.hosts.updatePage(page, pane: pane)
        if urlChanged {
            workspace.hosts.syncFavicons(tabs: workspace.tabs, surfaces: workspace.surfaces, pinned: workspace.savedSites.domains)
            if let url = page.url, url.absoluteString != "about:blank" {
                workspace.setLineFromHost(pane, url.absoluteString)
                if !page.isLoading { workspace.browserHistory.record(url, title: page.title) }
            }
        }
    }

    func chromiumPageDidCreate(_ page: ChromiumPage) { update(page) }
    func chromiumPageDidChange(_ page: ChromiumPage) { update(page) }

    func chromiumPageDidCommit(_ page: ChromiumPage) {
        workspace?.builtIns.navigated(pane)
        workspace?.assistance.committed(pane)
        workspace?.noteSiteMenuDocumentChanged(pane)
        update(page)
    }

    func chromiumPageDidFinish(_ page: ChromiumPage) {
        update(page)
        workspace?.hosts.loadFavicon(page, pane: pane, workspace: workspace)
        workspace?.hosts.restoreScrollIfNeeded(page, pane: pane)
        workspace?.assistance.loaded(pane, page: page)
        workspace?.browserHistory.record(page.url, title: page.title)
        workspace?.captureSiteMenu(pane)
    }

    func chromiumPage(_ page: ChromiumPage, didFail message: String) { update(page) }

    func chromiumPage(
        _ page: ChromiumPage,
        decideNavigationTo destination: URL,
        source: URL?,
        kind: NavigationKind,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard let workspace else { return false }
        let preliminary = NavigationSafety.review(destination: destination, source: source, kind: kind)
        let inspectLink = kind == .link && source.map { !NavigationSafety.sameSite($0, destination) } == true
        if preliminary.disposition == .allow, !inspectLink { return false }
        if preliminary.disposition == .warn,
           workspace.navigationExceptions.contains(preliminary), !inspectLink { return false }
        Task { @MainActor [weak self, weak page] in
            guard let self, let page, let workspace = self.workspace,
                  workspace.hosts.existingBrowser(self.pane) === page else {
                completion(false)
                return
            }
            let linkText = inspectLink ? await PageTextBridge.navigationLinkText(page, destination: destination) : nil
            let review = NavigationSafety.review(
                destination: destination,
                source: source,
                kind: kind,
                linkText: linkText
            )
            completion(await self.allow(review, page: page, workspace: workspace))
        }
        return true
    }

    func chromiumPage(
        _ page: ChromiumPage,
        decidePermissionFor originValue: String,
        kind: WebsitePermissionKind,
        completion: @escaping (Bool) -> Void
    ) {
        guard workspace != nil, let origin = BrowserPrompts.permissionOrigin(originValue) else {
            completion(false)
            return
        }
        Task { @MainActor [weak self, weak page] in
            guard let self, let page, let workspace = self.workspace,
                  workspace.hosts.existingBrowser(self.pane) === page else {
                completion(false)
                return
            }
            let decision = await BrowserPrompts.requestPermission(
                origin: origin,
                kind: kind,
                store: workspace.permissions,
                window: page.window
            )
            completion(decision == .allow)
        }
    }

    func chromiumPage(
        _ page: ChromiumPage,
        decideDownloadFrom source: URL?,
        to destination: URL,
        completion: @escaping (Bool) -> Void
    ) {
        guard workspace != nil else {
            completion(false)
            return
        }
        let review = NavigationSafety.review(destination: destination, source: source, kind: .download)
        Task { @MainActor [weak self, weak page] in
            guard let self, let page, let workspace = self.workspace,
                  workspace.hosts.existingBrowser(self.pane) === page else {
                completion(false)
                return
            }
            completion(await self.allow(review, page: page, workspace: workspace))
        }
    }

    func chromiumPage(_ page: ChromiumPage, didRejectCertificateAt url: URL, error: String) {
        Task { @MainActor [weak page] in
            await BrowserPrompts.showCertificateError(url: url, error: error, window: page?.window)
        }
    }

    func chromiumPageWebContentProcessDidTerminate(_ page: ChromiumPage) {
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self, let page, let workspace = self.workspace else { return }
            workspace.hosts.handleWebContentTermination(page, pane: self.pane, workspace: workspace)
        }
    }

    func chromiumPage(_ page: ChromiumPage, requestedPopup url: URL, userGesture: Bool) {
        // Pages must not open file:, data:, or custom-scheme tabs on their own.
        guard userGesture, let destination = ExternalURLRouting.webURL(url), workspace != nil else { return }
        let review = NavigationSafety.review(destination: destination, source: page.url, kind: .popup)
        Task { @MainActor [weak self, weak page] in
            guard let self, let page, let workspace = self.workspace,
                  workspace.hosts.existingBrowser(self.pane) === page,
                  await self.allow(review, page: page, workspace: workspace) else { return }
            workspace.openAddress(destination.absoluteString)
        }
    }

    func chromiumPage(_ page: ChromiumPage, didStartDownload identifier: UInt32, url: URL, suggestedFilename: String) {
        workspace?.downloads.begin(page: page, identifier: identifier, url: url, suggestedFilename: suggestedFilename)
    }

    func chromiumPage(_ page: ChromiumPage, didUpdateDownload identifier: UInt32, fullPath: String, receivedBytes: Int64, totalBytes: Int64, percent: Int, complete: Bool, cancelled: Bool, interrupted: Bool) {
        workspace?.downloads.update(page: page, identifier: identifier, fullPath: fullPath, receivedBytes: receivedBytes, totalBytes: totalBytes, percent: percent, complete: complete, cancelled: cancelled, interrupted: interrupted)
    }

    func chromiumPage(_ page: ChromiumPage, didBlockRequests count: Int) {
        workspace?.builtIns.blocked(count, pane: pane)
    }

    func chromiumPageDidClose(_ page: ChromiumPage) {}

    private func allow(_ review: NavigationReview, page: ChromiumPage, workspace: Workspace) async -> Bool {
        if review.disposition == .allow || workspace.navigationExceptions.contains(review) { return true }
        let advice = review.disposition == .warn
            ? await workspace.assistance.navigationAdvice(review)
            : nil
        return await BrowserPrompts.confirmNavigation(
            review,
            advice: advice,
            store: workspace.navigationExceptions,
            window: page.window
        )
    }
}
