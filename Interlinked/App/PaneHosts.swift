import AppKit
import Dispatch
import Observation

/// Retains pages and their state while background tabs leave the window.
@MainActor
@Observable
final class PaneHosts {
    @ObservationIgnored private var browsers: [PaneID: WebKitPage] = [:]
    @ObservationIgnored private var coordinators: [PaneID: BrowserCoordinator] = [:]
    @ObservationIgnored private var uploadPanes: Set<PaneID> = []
    @ObservationIgnored private var pendingScroll: [PaneID: Double] = [:]
    @ObservationIgnored private var savedScroll: [PaneID: ScrollMark] = [:]
    @ObservationIgnored private var memorySource: DispatchSourceMemoryPressure?
    /// One discard pass at a time; a critical event during a warning pass runs
    /// again afterwards, counting from the pages still live.
    @ObservationIgnored private var discarding = false
    @ObservationIgnored private var pendingPressure: TabMemoryPressure?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var sleepingIdle = false
    @ObservationIgnored private var iconTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var iconCache = DomainIconCache<NSImage>()
    @ObservationIgnored private let iconStore = DomainIconStore()
    @ObservationIgnored private var pageURLs: [PaneID: URL] = [:]
    private(set) var titles: [PaneID: String] = [:]
    private(set) var favicons: [PaneID: NSImage] = [:]
    private(set) var canGoBack: [PaneID: Bool] = [:]
    private(set) var canGoForward: [PaneID: Bool] = [:]
    private(set) var lifecycle = TabLifecycleLedger()

    func browser(for pane: PaneID, workspace: Workspace) -> WebKitPage {
        if let existing = browsers[pane] {
            lifecycle.touch(pane)
            return existing
        }
        let coordinator = BrowserCoordinator(pane: pane, workspace: workspace)
        let initialURL = address(from: workspace.surfaces.line(pane))
        let page = WebKitPage(initialURL: initialURL)
        page.forcedDarkMode = workspace.builtIns.darkens(initialURL)
        page.sharingScreenShield = workspace.sharingScreenMode
        page.delegate = coordinator
        coordinators[pane] = coordinator
        browsers[pane] = page
        lifecycle.register(pane)
        lifecycle.touch(pane)
        return page
    }

    func forget(keep: (PaneID) -> Bool, downloads: DownloadCenter) {
        let tracked = Set(browsers.keys).union(lifecycle.panes)
        for pane in tracked where !keep(pane) {
            removeBrowser(pane, downloads: downloads)
            lifecycle.close(pane)
            uploadPanes.remove(pane)
            pendingScroll.removeValue(forKey: pane)
            savedScroll.removeValue(forKey: pane)
            pageURLs.removeValue(forKey: pane)
            titles.removeValue(forKey: pane)
            favicons.removeValue(forKey: pane)
            canGoBack.removeValue(forKey: pane)
            canGoForward.removeValue(forKey: pane)
        }
    }

    func existingBrowser(_ pane: PaneID) -> WebKitPage? { browsers[pane] }
    func forEachBrowser(_ body: (WebKitPage) -> Void) { browsers.values.forEach(body) }
    func pane(of page: WebKitPage) -> PaneID? { browsers.first { $0.value === page }?.key }
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

    func updatePage(_ page: WebKitPage, pane: PaneID) {
        guard browsers[pane] === page else { return }
        if pageURLs[pane] != page.url {
            pageURLs[pane] = page.url
            lifecycle.touch(pane)
        }
        let title = page.title ?? ""
        if titles[pane] != title { titles[pane] = title }
        if canGoBack[pane] != page.canGoBack { canGoBack[pane] = page.canGoBack }
        if canGoForward[pane] != page.canGoForward { canGoForward[pane] = page.canGoForward }
    }

    func syncFavicons(tabs: [Tab], surfaces: Surfaces) {
        var owners: [PaneID: String] = [:]
        // Both pages of a split show their icon, so both keep their host open.
        for tab in tabs {
            for pane in tab.panes {
                let url = pageURLs[pane] ?? address(from: surfaces.line(pane))
                owners[pane] = DomainIconCache<NSImage>.domain(url)
            }
        }
        for domain in iconCache.retain(owners) { iconTasks.removeValue(forKey: domain)?.cancel() }
        for domain in Set(owners.values) where !iconCache.contains(domain) {
            guard let data = iconStore.data(for: domain) else { continue }
            guard let image = NSImage(data: data) else { continue }
            _ = iconCache.restore(domain, value: image)
        }
        publishFavicons()
    }

    private func publishFavicons() {
        let images = iconCache.owners.keys.reduce(into: [PaneID: NSImage]()) { result, pane in
            result[pane] = iconCache.value(for: pane)
        }
        if images != favicons { favicons = images }
    }

    func loadFavicon(_ page: WebKitPage, pane: PaneID, workspace: Workspace? = nil) {
        guard let pageURL = page.url, let domain = DomainIconCache<NSImage>.domain(pageURL),
              let token = iconCache.begin(domain) else { return }
        iconTasks[domain] = Task { [weak self, weak page, weak workspace] in
            let deadline = ContinuousClock.now + FaviconDownload.deadline
            let script = "Array.from(document.querySelectorAll('link[rel]')).filter(l => l.rel.split(/\\s+/).some(r => r === 'icon' || r === 'apple-touch-icon')).map(l => l.href).slice(0, 4)"
            let links = (try? await page?.evaluateJavaScript(script)) as? [String] ?? []
            var candidates = DomainIconCache<NSImage>.domain(page?.url) == domain ? links.compactMap(URL.init(string:)) : []
            if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { candidates.append(fallback) }
            var icon: NSImage?
            var iconData: Data?
            var tried: Set<URL> = []
            for url in candidates where ["https", "http"].contains(url.scheme ?? "") && tried.insert(url).inserted {
                guard !Task.isCancelled else { return }
                // Past the deadline the domain completes without an icon.
                guard ContinuousClock.now < deadline else { break }
                // Favicons are immutable enough to honor HTTP/URLCache semantics.
                // Bypassing the cache here duplicated network work on retries
                // and revisits before the persistent icon store was populated.
                let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
                guard let data = await FaviconDownload.data(for: request, until: deadline),
                      let image = NSImage(data: data) else { continue }
                icon = image
                iconData = data
                break
            }
            guard !Task.isCancelled, let self,
                  self.iconCache.complete(domain, token: token, value: icon) else { return }
            if let iconData {
                try? self.iconStore.write(iconData, for: domain)
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
                await self.relieveMemoryPressure(pressure, workspace: workspace)
            }
        }
        source.resume()
    }

    func stopMemoryPressureMonitoring() {
        memorySource?.cancel()
        memorySource = nil
    }

    func handleWebContentTermination(_ page: WebKitPage, pane: PaneID, workspace: Workspace) {
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

    /// A position from the last session, put back on the page's first load
    /// only if it is still the same document.
    func expectScroll(_ mark: ScrollMark) {
        savedScroll[mark.pane] = mark
    }

    func restoreScrollIfNeeded(_ page: WebKitPage, pane: PaneID) {
        let saved = savedScroll.removeValue(forKey: pane).flatMap { $0.fits(url: page.url, title: page.title) ? $0.y : nil }
        guard let y = pendingScroll.removeValue(forKey: pane) ?? saved, y > 0 else { return }
        page.evaluateJavaScript("window.scrollTo(0, \(y))")
    }

    private func relieveMemoryPressure(_ pressure: TabMemoryPressure, workspace: Workspace) async {
        if discarding {
            if pendingPressure != .critical { pendingPressure = pressure }
            return
        }
        discarding = true
        defer { discarding = false }
        var next: TabMemoryPressure? = pressure
        while let pressure = next {
            pendingPressure = nil
            await discardBackgroundTabs(pressure: pressure, workspace: workspace)
            next = pendingPressure
        }
    }

    private func discardBackgroundTabs(pressure: TabMemoryPressure, workspace: Workspace) async {
        let goal = TabMemoryPolicy.discardCount(liveCount: browsers.count, pressure: pressure)
        guard goal > 0 else { return }
        var discarded = 0
        for pane in TabMemoryPolicy.orderedDiscardCandidates(sleepCandidates(workspace: workspace)) where discarded < goal {
            if await putToSleep(pane, cause: .memoryPressure, workspace: workspace) { discarded += 1 }
        }
    }

    /// Every few minutes, background tabs left alone for half an hour go to
    /// sleep, under the same protections as for memory pressure. They wake
    /// when shown.
    func startIdleSleep(workspace: Workspace) {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self, weak workspace] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, let self, let workspace else { return }
                await self.sleepIdleTabs(workspace: workspace)
            }
        }
    }

    func stopIdleSleep() {
        idleTask?.cancel()
        idleTask = nil
    }

    func sleepIdleTabs(workspace: Workspace, after: TimeInterval = TabMemoryPolicy.idleSleepAfter) async {
        // Its own flag, so memory pressure arriving meanwhile is still
        // handled. A page both passes pick sleeps once: putToSleep checks
        // it again after the probe.
        guard !sleepingIdle else { return }
        sleepingIdle = true
        defer { sleepingIdle = false }
        // A tab counts as left alone from when it was last on screen, not
        // when it was opened.
        for pane in workspace.activeTab?.panes ?? [] where browsers[pane] != nil { lifecycle.touch(pane) }
        for pane in TabMemoryPolicy.idleCandidates(sleepCandidates(workspace: workspace), now: Date(), after: after) {
            await putToSleep(pane, cause: .idle, workspace: workspace)
        }
    }

    private func sleepCandidates(workspace: Workspace) -> [TabMemoryCandidate] {
        browsers.map { pane, page in
            var protections: TabDiscardProtection = []
            // Both pages of a split are on screen.
            if workspace.activeTab?.contains(pane) == true { protections.insert(.active) }
            if uploadPanes.contains(pane) { protections.insert(.upload) }
            if workspace.downloads.hasActiveDownload(for: page) { protections.insert(.download) }
            return TabMemoryCandidate(pane: pane, lastUsed: lifecycle.lastUsed[pane] ?? .distantPast,
                                      protections: protections)
        }
    }

    /// Frees `pane`'s page unless it plays media or holds unsaved form work.
    @discardableResult
    private func putToSleep(_ pane: PaneID, cause: BrowserRecoveryCause, workspace: Workspace) async -> Bool {
        guard let page = browsers[pane], let probe = await discardProbe(page), probe.safe else { return false }
        // The probe suspends, so the tab may have become active, started a
        // transfer, or been replaced in the meantime. Both pages of a split
        // are on screen.
        guard browsers[pane] === page, workspace.activeTab?.contains(pane) != true, !uploadPanes.contains(pane),
              !workspace.downloads.hasActiveDownload(for: page) else { return false }
        let url = page.url ?? pageURLs[pane] ?? address(from: workspace.surfaces.line(pane))
        lifecycle.suspend(pane, recovery: BrowserRecovery(cause: cause, url: url,
                                                           scrollY: probe.scrollY, occurredAt: Date()))
        pageURLs[pane] = url
        removeBrowser(pane, downloads: workspace.downloads)
        return true
    }

    /// A page stuck in a script never answers, and WebKit only fails the
    /// request when the page closes, so an unanswered probe counts as unsafe.
    private func discardProbe(_ page: WebKitPage) async -> BrowserDiscardProbe? {
        let answer = DiscardProbeAnswer()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            page.evaluateDiscardProbe { probe in
                MainActor.assumeIsolated { answer.finish(probe) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                answer.finish(nil)
            }
        }
    }

    private func removeBrowser(_ pane: PaneID, downloads: DownloadCenter) {
        guard let page = browsers.removeValue(forKey: pane) else {
            coordinators.removeValue(forKey: pane)
            return
        }
        // Cancel first while the delegate is still attached; the cancellation
        // can no longer reach DownloadCenter once we detach below.
        downloads.interruptDownloads(for: page)
        page.delegate = nil
        page.close()
        coordinators.removeValue(forKey: pane)
    }
}

/// Resumes a discard probe once, with the page's answer or the timeout.
@MainActor
private final class DiscardProbeAnswer {
    var continuation: CheckedContinuation<BrowserDiscardProbe?, Never>?

    func finish(_ probe: BrowserDiscardProbe?) {
        continuation?.resume(returning: probe)
        continuation = nil
    }
}

@MainActor
final class BrowserCoordinator: WebKitPageDelegate {
    let pane: PaneID
    weak var workspace: Workspace?
    private var navigation = PageNavigationTracker()

    init(pane: PaneID, workspace: Workspace) {
        self.pane = pane
        self.workspace = workspace
    }

    private func update(_ page: WebKitPage) {
        apply(navigation.addressChanged(to: page.url), page: page)
    }

    private func apply(_ effects: PageNavigationEffects, page: WebKitPage) {
        guard let workspace else { return }
        if effects.contains(.newDocument) {
            workspace.assistance.committed(pane)
            workspace.usefulInfo.committed(pane)
            workspace.noteDocumentChanged(pane, url: page.url)
        }
        if effects.contains(.newAddress) { workspace.builtIns.apply(to: page) }
        workspace.hosts.updatePage(page, pane: pane)
        if effects.rereadsPage(loading: page.isLoading) {
            workspace.assistance.loaded(pane, page: page)
            workspace.usefulInfo.loaded(pane, page: page)
        }
        if effects.contains(.newAddress) {
            workspace.hosts.syncFavicons(tabs: workspace.tabs, surfaces: workspace.surfaces)
            if let url = page.url, url.absoluteString != "about:blank" {
                workspace.setLineFromHost(pane, url.absoluteString)
                if !page.isLoading { workspace.browserHistory.record(url, title: page.title) }
            }
        }
    }

    func pageDidChange(_ page: WebKitPage) { update(page) }

    func pageDidCommit(_ page: WebKitPage) {
        apply(navigation.committed(to: page.url), page: page)
    }

    func pageDidFinish(_ page: WebKitPage) {
        update(page)
        workspace?.hosts.loadFavicon(page, pane: pane, workspace: workspace)
        workspace?.hosts.restoreScrollIfNeeded(page, pane: pane)
        workspace?.assistance.loaded(pane, page: page)
        workspace?.usefulInfo.loaded(pane, page: page)
        workspace?.browserHistory.record(page.url, title: page.title)
    }

    func page(_ page: WebKitPage, didFail message: String) { update(page) }

    func page(_ page: WebKitPage, opensApp url: URL) {
        Task { @MainActor [weak self, weak page] in
            guard let self, let page, let workspace = self.workspace,
                  workspace.hosts.existingBrowser(self.pane) === page,
                  await BrowserPrompts.confirmOpeningApp(for: url, window: page.window) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func page(
        _ page: WebKitPage,
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

    func page(_ page: WebKitPage, didRejectCertificateAt url: URL, error: String) {
        Task { @MainActor [weak page] in
            await BrowserPrompts.showCertificateError(url: url, error: error, window: page?.window)
        }
    }

    func pageWebContentProcessDidTerminate(_ page: WebKitPage) {
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self, let page, let workspace = self.workspace else { return }
            workspace.hosts.handleWebContentTermination(page, pane: self.pane, workspace: workspace)
        }
    }

    func page(_ page: WebKitPage, requestedPopup url: URL) {
        // Pages must not open file:, data:, or custom-scheme tabs on their own.
        guard let destination = ExternalURLRouting.webURL(url) else { return }
        workspace?.openAddress(destination.absoluteString)
    }

    func page(_ page: WebKitPage, didStartDownload identifier: UInt32, url: URL, suggestedFilename: String) {
        workspace?.downloads.begin(page: page, identifier: identifier, url: url, suggestedFilename: suggestedFilename)
    }

    func page(_ page: WebKitPage, didUpdateDownload identifier: UInt32, fullPath: String, receivedBytes: Int64, totalBytes: Int64, percent: Int, complete: Bool, cancelled: Bool, interrupted: Bool) {
        workspace?.downloads.update(page: page, identifier: identifier, fullPath: fullPath, receivedBytes: receivedBytes, totalBytes: totalBytes, percent: percent, complete: complete, cancelled: cancelled, interrupted: interrupted)
    }

    func pageWillChooseFiles(_ page: WebKitPage) { workspace?.hosts.beginUpload(pane) }
    func pageDidChooseFiles(_ page: WebKitPage) { workspace?.hosts.endUpload(pane) }
}
