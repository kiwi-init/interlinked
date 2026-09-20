import AppKit
import Dispatch
import Observation
import WebKit

/// Retains web views and their state while background tabs leave the window.
@MainActor
@Observable
final class PaneHosts {
    @ObservationIgnored private var browsers: [PaneID: WKWebView] = [:]
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

    func browser(for pane: PaneID, workspace: Workspace) -> WKWebView {
        if let existing = browsers[pane] {
            lifecycle.touch(pane)
            return existing
        }
        let config = WKWebViewConfiguration()
        let coordinator = BrowserCoordinator(pane: pane, workspace: workspace)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        NavigationSafety.configure(config.preferences)
        config.userContentController.addUserScript(WKUserScript(
            source: PageTextBridge.install,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        if #available(macOS 12.3, *) {
            config.preferences.isElementFullscreenEnabled = true
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        coordinators[pane] = coordinator
        browsers[pane] = view
        lifecycle.register(pane)
        lifecycle.touch(pane)
        coordinator.observe(view)
        return view
    }

    func forget(keep: (PaneID) -> Bool, kinds: (PaneID) -> Kind) {
        let tracked = Set(browsers.keys).union(lifecycle.panes)
        for pane in tracked where !keep(pane) || kinds(pane) != .browser {
            removeBrowser(pane)
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

    func existingBrowser(_ pane: PaneID) -> WKWebView? {
        browsers[pane]
    }

    func touch(_ pane: PaneID) {
        lifecycle.touch(pane)
    }

    func recovery(for pane: PaneID) -> BrowserRecovery? {
        lifecycle.recoveries[pane]
    }

    func beginRecovery(_ pane: PaneID) -> BrowserRecovery? {
        guard let recovery = lifecycle.takeRecovery(pane) else { return nil }
        if recovery.scrollY > 0 { pendingScroll[pane] = recovery.scrollY }
        return recovery
    }

    func beginUpload(_ pane: PaneID) {
        uploadPanes.insert(pane)
    }

    func endUpload(_ pane: PaneID) {
        uploadPanes.remove(pane)
    }

    func focus(_ pane: PaneID) {
        let view: NSView? = browsers[pane]
        if let view { view.window?.makeFirstResponder(view) }
    }

    func updatePage(_ view: WKWebView, pane: PaneID) {
        guard browsers[pane] === view else { return }
        if pageURLs[pane] != view.url {
            pageURLs[pane] = view.url
            previews.removeValue(forKey: pane)
            lifecycle.touch(pane)
        }
        let title = view.title ?? ""
        if titles[pane] != title { titles[pane] = title }
        if canGoBack[pane] != view.canGoBack { canGoBack[pane] = view.canGoBack }
        if canGoForward[pane] != view.canGoForward { canGoForward[pane] = view.canGoForward }
    }

    func capturePreviews() {
        for (pane, view) in browsers where view.window != nil { capture(view, pane: pane) }

    }

    func capture(_ view: WKWebView, pane: PaneID) {
        guard view.bounds.width > 0, view.bounds.height > 0, !capturing.contains(pane) else { return }
        capturing.insert(pane)
        let url = view.url
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 600
        view.takeSnapshot(with: config) { [weak self, weak view] image, _ in
            guard let self else { return }
            self.capturing.remove(pane)
            guard let view, self.browsers[pane] === view, view.url == url, let image else { return }
            self.previews[pane] = image
        }
    }

    func syncFavicons(tabs: [Tab], surfaces: Surfaces) {
        var owners: [PaneID: String] = [:]
        for tab in tabs {
            let pane = tab.active
            let url = pageURLs[pane] ?? address(from: surfaces.line(pane))
            owners[pane] = DomainIconCache<NSImage>.domain(url)
        }
        for domain in iconCache.retain(owners) { iconTasks.removeValue(forKey: domain)?.cancel() }
        for domain in Set(owners.values) where !iconCache.contains(domain) {
            guard let data = iconStore.data(for: domain) else { continue }
            guard let image = NSImage(data: data) else {
                iconStore.remove(domain)
                continue
            }
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

    func loadFavicon(_ view: WKWebView, pane: PaneID) {
        guard let page = view.url, let domain = DomainIconCache<NSImage>.domain(page),
              let token = iconCache.begin(domain) else { return }
        iconTasks[domain] = Task { [weak self, weak view] in
            let script = "Array.from(document.querySelectorAll('link[rel]')).filter(l => l.rel.split(/\\s+/).some(r => r === 'icon' || r === 'apple-touch-icon')).map(l => l.href).slice(0, 4)"
            let links = (try? await view?.evaluateJavaScript(script)) as? [String] ?? []
            var candidates = DomainIconCache<NSImage>.domain(view?.url) == domain ? links.compactMap(URL.init(string:)) : []
            if let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL { candidates.append(fallback) }
            var icon: NSImage?
            var iconData: Data?
            var tried: Set<URL> = []
            for url in candidates where ["https", "http"].contains(url.scheme ?? "") && tried.insert(url).inserted {
                guard !Task.isCancelled else { return }
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count < 1_048_576, let image = NSImage(data: data) else { continue }
                icon = image
                iconData = data
                break
            }
            guard !Task.isCancelled, let self,
                  self.iconCache.complete(domain, token: token, value: icon) else { return }
            if let iconData { try? self.iconStore.write(iconData, for: domain) }
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

    func handleWebContentTermination(_ view: WKWebView, pane: PaneID, workspace: Workspace) {
        guard browsers[pane] === view else { return }
        let url = view.url ?? pageURLs[pane] ?? address(from: workspace.surfaces.line(pane))
        lifecycle.suspend(pane, recovery: BrowserRecovery(
            cause: .webContentTerminated,
            url: url,
            scrollY: 0,
            occurredAt: Date()
        ))
        pageURLs[pane] = url
        removeBrowser(pane)
    }

    func restoreScrollIfNeeded(_ view: WKWebView, pane: PaneID) {
        guard let y = pendingScroll.removeValue(forKey: pane), y > 0 else { return }
        view.evaluateJavaScript("window.scrollTo(0, \(y))")
    }

    private func discardBackgroundTabs(pressure: TabMemoryPressure, workspace: Workspace) async {
        let goal = TabMemoryPolicy.discardCount(liveCount: browsers.count, pressure: pressure)
        guard goal > 0 else { return }
        let candidates = browsers.map { pane, view in
            var protections: TabDiscardProtection = []
            if pane == workspace.activePane { protections.insert(.active) }
            if uploadPanes.contains(pane) { protections.insert(.upload) }
            if workspace.downloads.hasActiveDownload(for: view) { protections.insert(.download) }
            return TabMemoryCandidate(
                pane: pane,
                lastUsed: lifecycle.lastUsed[pane] ?? .distantPast,
                protections: protections
            )
        }

        var discarded = 0
        for pane in TabMemoryPolicy.orderedDiscardCandidates(candidates) where discarded < goal {
            guard let view = browsers[pane], let probe = await discardProbe(view), probe.safe else { continue }
            let url = view.url ?? pageURLs[pane] ?? address(from: workspace.surfaces.line(pane))
            lifecycle.suspend(pane, recovery: BrowserRecovery(
                cause: .memoryPressure,
                url: url,
                scrollY: probe.scrollY,
                occurredAt: Date()
            ))
            pageURLs[pane] = url
            removeBrowser(pane)
            discarded += 1
        }
    }

    private func discardProbe(_ view: WKWebView) async -> BrowserDiscardProbe? {
        guard let value = try? await view.evaluateJavaScript(BrowserDiscardProbe.script) else { return nil }
        return BrowserDiscardProbe.decode(value)
    }

    private func removeBrowser(_ pane: PaneID) {
        guard let view = browsers.removeValue(forKey: pane) else {
            coordinators.removeValue(forKey: pane)
            return
        }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        coordinators.removeValue(forKey: pane)
    }

}

@MainActor
final class BrowserCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let pane: PaneID
    weak var workspace: Workspace?
    private var observations: [NSKeyValueObservation] = []
    private var lastURL: URL?
    private var updateScheduled = false

    init(pane: PaneID, workspace: Workspace) {
        self.pane = pane
        self.workspace = workspace
    }

    func observe(_ view: WKWebView) {
        observations = [
            view.observe(\.title) { [weak self] view, _ in
                Task { @MainActor in self?.scheduleUpdate(view) }
            },
            view.observe(\.url) { [weak self] view, _ in
                Task { @MainActor in self?.scheduleUpdate(view) }
            },
            view.observe(\.canGoBack) { [weak self] view, _ in
                Task { @MainActor in self?.scheduleUpdate(view) }
            },
            view.observe(\.canGoForward) { [weak self] view, _ in
                Task { @MainActor in self?.scheduleUpdate(view) }
            },
        ]
    }

    private func scheduleUpdate(_ view: WKWebView) {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self else { return }
            self.updateScheduled = false
            if let view { self.update(view) }
        }
    }

    private func update(_ view: WKWebView) {
        guard let workspace else { return }
        let urlChanged = lastURL != view.url
        if urlChanged {
            lastURL = view.url
            workspace.assistance.committed(pane)
            workspace.assistance.loaded(pane, view: view)
        }
        workspace.hosts.updatePage(view, pane: pane)
        if urlChanged {
            workspace.hosts.syncFavicons(tabs: workspace.tabs, surfaces: workspace.surfaces)
            if let url = view.url, url.absoluteString != "about:blank" {
                workspace.setLineFromHost(pane, url.absoluteString)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        update(webView)
        workspace?.hosts.loadFavicon(webView, pane: pane)
        workspace?.hosts.restoreScrollIfNeeded(webView, pane: pane)
        workspace?.assistance.loaded(pane, view: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        workspace?.assistance.committed(pane)
        update(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let workspace else { return }
        workspace.hosts.handleWebContentTermination(webView, pane: pane, workspace: workspace)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let destination = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        let source = navigationAction.sourceFrame.request.url ?? webView.url
        let kind = navigationKind(navigationAction.navigationType)
        let preliminary = NavigationSafety.review(destination: destination, source: source, kind: kind)
        let inspectLink = kind == .link && source.map { !NavigationSafety.sameSite($0, destination) } == true
        guard preliminary.disposition != .allow || inspectLink else {
            decisionHandler(.allow, preferences)
            return
        }
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else {
                decisionHandler(.cancel, preferences)
                return
            }
            let linkText = inspectLink ? await PageTextBridge.navigationLinkText(webView, destination: destination) : nil
            let review = NavigationSafety.review(destination: destination, source: source, kind: kind, linkText: linkText)
            guard review.disposition != .allow else {
                decisionHandler(.allow, preferences)
                return
            }
            let advice = review.disposition == .warn
                ? await workspace?.assistance.navigationAdvice(review)
                : nil
            let allowed = await confirmNavigation(review, advice: advice, window: webView.window)
            decisionHandler(allowed ? .allow : .cancel, preferences)
        }
    }

    private func navigationKind(_ type: WKNavigationType) -> NavigationKind {
        switch type {
        case .linkActivated: return .link
        case .formSubmitted, .formResubmitted: return .form
        case .backForward: return .history
        case .reload: return .reload
        default: return .other
        }
    }

    private func confirmNavigation(_ review: NavigationReview, advice: String?, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        let blocked = review.disposition == .block
        alert.alertStyle = .warning
        alert.messageText = blocked ? "Interlinked blocked this navigation" : "Check where this link is going"
        var details = ["Destination: \(review.destinationOrigin)"]
        if let source = review.sourceOrigin { details.append("From: \(source)") }
        details.append(contentsOf: review.reasons.map(\.rawValue))
        if let advice, !advice.isEmpty { details.append(advice) }
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: blocked ? "OK" : "Go Back")
        if !blocked { alert.addButton(withTitle: "Continue") }
        guard !blocked else {
            if let window { await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { _ in continuation.resume() } } }
            else { alert.runModal() }
            return false
        }
        if let window {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertSecondButtonReturn) }
            }
        }
        return alert.runModal() == .alertSecondButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        workspace?.downloads.track(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        workspace?.downloads.track(download)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else { return nil }
        let source = navigationAction.sourceFrame.request.url ?? webView.url
        let kind = navigationKind(navigationAction.navigationType)
        let preliminary = NavigationSafety.review(destination: url, source: source, kind: kind)
        let inspectLink = kind == .link && source.map { !NavigationSafety.sameSite($0, url) } == true
        guard preliminary.disposition != .allow || inspectLink else {
            workspace?.openAddress(url.absoluteString)
            return nil
        }
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            let linkText = inspectLink ? await PageTextBridge.navigationLinkText(webView, destination: url) : nil
            let review = NavigationSafety.review(destination: url, source: source, kind: kind, linkText: linkText)
            if review.disposition == .allow {
                workspace?.openAddress(url.absoluteString)
                return
            }
            let advice = review.disposition == .warn
                ? await workspace?.assistance.navigationAdvice(review)
                : nil
            if await confirmNavigation(review, advice: advice, window: webView.window) {
                workspace?.openAddress(url.absoluteString)
            }
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let kind: WebsitePermissionKind
        switch type {
        case .camera: kind = .camera
        case .microphone: kind = .microphone
        case .cameraAndMicrophone: kind = .cameraAndMicrophone
        @unknown default:
            decisionHandler(.deny)
            return
        }
        Task { @MainActor [weak self, weak webView] in
            guard let self, let workspace else {
                decisionHandler(.deny)
                return
            }
            let decision = await WebPrompts.requestPermission(
                origin: WebPrompts.origin(origin), kind: kind,
                store: workspace.permissions, window: webView?.window
            )
            decisionHandler(decision == .allow ? .grant : .deny)
        }
    }

    @available(macOS 27.0, *)
    func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        Task { @MainActor [weak self, weak webView] in
            guard let self, let workspace else {
                decisionHandler(.deny)
                return
            }
            let decision = await WebPrompts.requestPermission(
                origin: WebPrompts.origin(origin), kind: .location,
                store: workspace.permissions, window: webView?.window
            )
            decisionHandler(decision == .allow ? .grant : .deny)
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else {
                completionHandler(nil)
                return
            }
            self.workspace?.hosts.beginUpload(self.pane)
            let script = "document.activeElement instanceof HTMLInputElement ? document.activeElement.accept : ''"
            let accepted = (try? await webView.evaluateJavaScript(script)) as? String
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            let types = WebPrompts.acceptedContentTypes(accepted)
            if !types.isEmpty { panel.allowedContentTypes = types }
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                if let self { self.workspace?.hosts.endUpload(self.pane) }
                completionHandler(response == .OK ? panel.urls : nil)
            }
            if let window = webView.window {
                panel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                panel.begin(completionHandler: finish)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak webView] in
            await WebPrompts.showAlert(message: message, origin: WebPrompts.origin(frame), window: webView?.window)
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor [weak webView] in
            let confirmed = await WebPrompts.showConfirm(
                message: message, origin: WebPrompts.origin(frame), window: webView?.window
            )
            completionHandler(confirmed)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        Task { @MainActor [weak webView] in
            let answer = await WebPrompts.showPrompt(
                message: prompt, defaultText: defaultText,
                origin: WebPrompts.origin(frame), window: webView?.window
            )
            completionHandler(answer)
        }
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Task { @MainActor [weak webView] in
            let response = await WebPrompts.authenticationResponse(for: challenge, window: webView?.window)
            completionHandler(response.0, response.1)
        }
    }
}
