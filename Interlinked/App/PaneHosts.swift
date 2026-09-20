import AppKit
import Observation
import WebKit

/// Retains web views and their state while background tabs leave the window.
@MainActor
@Observable
final class PaneHosts {
    @ObservationIgnored private var browsers: [PaneID: WKWebView] = [:]
    @ObservationIgnored private var coordinators: [PaneID: BrowserCoordinator] = [:]
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

    func browser(for pane: PaneID, workspace: Workspace) -> WKWebView {
        if let existing = browsers[pane] { return existing }
        let config = WKWebViewConfiguration()
        let coordinator = BrowserCoordinator(pane: pane, workspace: workspace)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
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
        coordinator.observe(view)
        return view
    }

    func forget(keep: (PaneID) -> Bool, kinds: (PaneID) -> Kind) {
        for pane in browsers.keys where !keep(pane) || kinds(pane) != .browser {
            browsers[pane]?.stopLoading()
            browsers.removeValue(forKey: pane)
            coordinators.removeValue(forKey: pane)
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

    func focus(_ pane: PaneID) {
        let view: NSView? = browsers[pane]
        if let view { view.window?.makeFirstResponder(view) }
    }

    func updatePage(_ view: WKWebView, pane: PaneID) {
        guard browsers[pane] === view else { return }
        if pageURLs[pane] != view.url {
            pageURLs[pane] = view.url
            previews.removeValue(forKey: pane)
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

}

@MainActor
final class BrowserCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
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
        workspace?.assistance.loaded(pane, view: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        workspace?.assistance.committed(pane)
        update(webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { result in
                completionHandler(result == .OK ? panel.url : nil)
            }
        } else {
            panel.begin { result in
                completionHandler(result == .OK ? panel.url : nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else { return nil }
        workspace?.openAddress(url.absoluteString)
        return nil
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
    }
}
