import AppKit
import WebKit

extension WebKitPage: PageJavaScriptEvaluating {
    /// WebKit runs every script the browser evaluates as a user gesture, so
    /// `userGesture` cannot withhold one.
    func interlinkedEvaluate(_ body: String, arguments: [String: Any], userGesture: Bool) async throws -> Any? {
        try await nativeView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
    }
}

@MainActor
protocol WebKitPageDelegate: AnyObject {
    func pageDidChange(_ page: WebKitPage)
    func pageDidCommit(_ page: WebKitPage)
    func pageDidFinish(_ page: WebKitPage)
    func page(_ page: WebKitPage, didFail message: String)
    /// A link or script asked for a new window, which becomes a new tab.
    /// WebKit asks only for windows a person opened.
    func page(_ page: WebKitPage, requestedPopup url: URL)
    func page(_ page: WebKitPage, didStartDownload identifier: UInt32, url: URL, suggestedFilename: String)
    func page(_ page: WebKitPage, didUpdateDownload identifier: UInt32, fullPath: String, receivedBytes: Int64, totalBytes: Int64, percent: Int, complete: Bool, cancelled: Bool, interrupted: Bool)
    /// Returns false to allow the navigation now, or true and later calls
    /// `completion` exactly once.
    func page(
        _ page: WebKitPage,
        decideNavigationTo destination: URL,
        source: URL?,
        kind: NavigationKind,
        completion: @escaping (Bool) -> Void
    ) -> Bool
    func page(
        _ page: WebKitPage,
        decidePermissionFor origin: String,
        kind: WebsitePermissionKind,
        completion: @escaping (Bool) -> Void
    )
    func page(
        _ page: WebKitPage,
        decideDownloadFrom source: URL?,
        to destination: URL,
        completion: @escaping (Bool) -> Void
    )
    func page(_ page: WebKitPage, didRejectCertificateAt url: URL, error: String)
    func pageWebContentProcessDidTerminate(_ page: WebKitPage)
    /// The page opened a file picker, which keeps it from being discarded.
    func pageWillChooseFiles(_ page: WebKitPage)
    func pageDidChooseFiles(_ page: WebKitPage)
}

/// The page's view. Interlinked's controls float over it; while the mouse is
/// over them the page does not see it move, so it cannot change the cursor or
/// show hover effects under the glass.
final class PageWebView: WKWebView {
    static var chromeOwnsCursor: (() -> Bool)?

    override func mouseMoved(with event: NSEvent) {
        if Self.chromeOwnsCursor?() == true { return }
        super.mouseMoved(with: event)
    }
}

/// Engine-owned page object used by the rest of Interlinked. SwiftUI receives
/// only `nativeView`; navigation and page operations stay behind this seam.
@MainActor
final class WebKitPage: NSObject {
    static let engineVersion: String = {
        let version = Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "WebKit \(version ?? "unknown")"
    }()

    /// Some sites serve a degraded page to WebKit browsers that do not name
    /// Safari. The system's Safari has the same major and minor version.
    private static let userAgentSuffix: String = {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(system.majorVersion).\(system.minorVersion) Safari/605.1.15"
    }()

    let nativeView: PageWebView
    weak var delegate: WebKitPageDelegate?

    var url: URL? { nativeView.url }
    var title: String? {
        let value = nativeView.title ?? ""
        return value.isEmpty ? nil : value
    }
    var isLoading: Bool { nativeView.isLoading }
    var canGoBack: Bool { nativeView.canGoBack }
    var canGoForward: Bool { nativeView.canGoForward }
    var window: NSWindow? { nativeView.window }
    /// Renders the page dark: its own dark theme if it has one, otherwise
    /// inverted.
    var forcedDarkMode = false {
        didSet {
            guard forcedDarkMode != oldValue else { return }
            nativeView.appearance = forcedDarkMode ? NSAppearance(named: .darkAqua) : nil
            installUserScripts()
            nativeView.evaluateJavaScript(forcedDarkMode ? DarkPage.script : DarkPage.stopScript, in: nil, in: DarkPage.world)
        }
    }
    var rendersDark: Bool { forcedDarkMode }
    /// Blurs sensitive text in every document this page loads.
    var sharingScreenShield = false {
        didSet {
            guard sharingScreenShield != oldValue else { return }
            installUserScripts()
            nativeView.evaluateJavaScript(sharingScreenShield ? SharingScreenShield.script : SharingScreenShield.stopScript,
                                          in: nil, in: .page)
        }
    }

    private var observations: [NSKeyValueObservation] = []
    /// The blocking scripts registered for the next document.
    private var blocking: DocumentBlocking?
    private var attachedRuleLists: [WKContentRuleList] = []
    /// The main frame's committed address: the page a navigation leaves.
    private var committedURL: URL?
    /// The last main-frame address the navigation policy allowed.
    private var allowedURL: URL?
    /// Where the provisional navigation began, and whether a server has
    /// redirected it since.
    private var chainStart: URL?
    private var provisional = false
    private var redirected = false
    /// A navigation restarted without its tracking parameters, which keeps
    /// the kind and source it was reviewed with.
    private var restarted: (url: URL, kind: NavigationKind, source: URL?)?
    private var certificateErrorReported = false
    /// Error pages are not documents the rest of Interlinked reads.
    private var errorPage: WKNavigation?
    /// A person edited something in a frame since the page last committed.
    private(set) var frameEdited = false
    private var errorPageURL: URL?
    /// The sign-in sheet a load is waiting on.
    private var signIn: NSAlert?
    private var downloads: [UInt32: WKDownload] = [:]
    private var downloadIDs: [ObjectIdentifier: UInt32] = [:]
    private var downloadDestinations: [UInt32: URL] = [:]
    private var downloadProgress: [UInt32: NSKeyValueObservation] = [:]
    private var downloadReportedAt: [UInt32: Date] = [:]
    private var cancelledDownloads: Set<UInt32> = []
    private var nextDownload: UInt32 = 0

    init(initialURL: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = Self.userAgentSuffix
        // Script popups need a person's click; WebKit drops the rest.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        nativeView = PageWebView(frame: .zero, configuration: configuration)
        super.init()
        nativeView.navigationDelegate = self
        nativeView.uiDelegate = self
        nativeView.allowsBackForwardNavigationGestures = true
        nativeView.allowsMagnification = true
        #if DEBUG
        // Safari's Develop menu can inspect development builds.
        nativeView.isInspectable = true
        #endif
        nativeView.configuration.userContentController.addScriptMessageHandler(
            CosmeticsReplies(page: self), contentWorld: ContentBlocker.cosmeticsWorld, name: ContentBlocker.cosmeticsHandler)
        nativeView.configuration.userContentController.add(
            FrameEdits(page: self), contentWorld: Self.editsWorld, name: BrowserDiscardProbe.frameEditHandler)
        observations = [
            nativeView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            nativeView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            nativeView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            nativeView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            nativeView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
        ]
        load(initialURL)
    }

    private func changed() { delegate?.pageDidChange(self) }

    func load(_ request: URLRequest) { nativeView.load(request) }
    func load(_ url: URL) { nativeView.load(URLRequest(url: url)) }
    func goBack() { nativeView.goBack() }
    func goForward() { nativeView.goForward() }
    func reload() { nativeView.reload() }
    func reloadFromOrigin() { nativeView.reloadFromOrigin() }
    func stopLoading() { nativeView.stopLoading() }
    func focus() { nativeView.window?.makeFirstResponder(nativeView) }

    /// Detaches the page and lets WebKit release it. Downloads already
    /// running keep going until cancelled.
    func close() {
        observations.removeAll()
        nativeView.navigationDelegate = nil
        nativeView.uiDelegate = nil
        nativeView.configuration.userContentController.removeAllScriptMessageHandlers()
        nativeView.stopLoading()
        nativeView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// Evaluates an expression in the page's world and waits for it when it
    /// is a promise.
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await nativeView.callAsyncJavaScript("return await (\n\(script)\n);", contentWorld: .page)
    }

    func evaluateJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        Task {
            do { completion?(try await evaluateJavaScript(script), nil) } catch { completion?(nil, error) }
        }
    }

    /// Where `BrowserDiscardProbe` records the fields a person changed.
    static let editsWorld = WKContentWorld.world(name: "interlinked-edits")

    /// Whether the page can sleep without losing anything, from the world
    /// that saw what the person changed. Nil when the page doesn't answer.
    func evaluateDiscardProbe(completion: @escaping (BrowserDiscardProbe?) -> Void) {
        Task {
            let value = try? await nativeView.callAsyncJavaScript("return \(BrowserDiscardProbe.script);",
                                                                 contentWorld: Self.editsWorld)
            guard var probe = BrowserDiscardProbe.decode(value) else { return completion(nil) }
            if frameEdited { probe.safe = false }
            completion(probe)
        }
    }

    func noteFrameEdit() { frameEdited = true }

    func find(_ text: String, backwards: Bool, findNext: Bool = true, completion: @escaping (Bool) -> Void) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        nativeView.find(text, configuration: configuration) { completion($0.matchFound) }
    }

    /// WebKit keeps the last match highlighted until a search misses, and
    /// leaves it selected.
    func stopFinding() {
        nativeView.find("\u{2063}" + UUID().uuidString, configuration: WKFindConfiguration()) { _ in }
        nativeView.evaluateJavaScript("getSelection()?.removeAllRanges()", in: nil, in: .defaultClient)
    }

    func snapshot(width: CGFloat = 600) async -> NSImage? {
        guard nativeView.bounds.width > 0, nativeView.bounds.height > 0 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(width))
        return try? await nativeView.takeSnapshot(configuration: configuration)
    }

    func cancelDownload(_ identifier: UInt32) {
        guard let download = downloads[identifier] else { return }
        cancelledDownloads.insert(identifier)
        download.cancel { [weak self] _ in
            MainActor.assumeIsolated { self?.reportDownload(identifier, cancelled: true) }
        }
    }

    /// The content blocking the current address calls for. New lists and
    /// settings reach the page's next requests; its scripts change with the
    /// next document.
    func refreshContentBlocking() {
        attachRuleLists(for: url)
    }

    // MARK: - Documents

    /// Registers what the next document at `url` needs before it loads.
    private func prepareDocument(for url: URL) {
        blocking = ContentBlocker.shared.documentBlocking(for: url)
        attachRuleLists(for: url)
        installUserScripts()
    }

    private func attachRuleLists(for url: URL?) {
        let wanted = ContentBlocker.shared.ruleLists(for: url)
        guard wanted.map(ObjectIdentifier.init) != attachedRuleLists.map(ObjectIdentifier.init) else { return }
        let controller = nativeView.configuration.userContentController
        controller.removeAllContentRuleLists()
        wanted.forEach(controller.add)
        attachedRuleLists = wanted
    }

    private func installUserScripts() {
        let controller = nativeView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: BrowserDiscardProbe.recordEdits, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: Self.editsWorld))
        if sharingScreenShield {
            controller.addUserScript(WKUserScript(source: SharingScreenShield.script, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: .page))
        }
        blocking?.scripts.forEach(controller.addUserScript)
        if forcedDarkMode {
            controller.addUserScript(WKUserScript(source: DarkPage.script, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: DarkPage.world))
        }
    }

    fileprivate func genericSelectors(_ message: WKScriptMessage) -> [String] {
        guard let payload = message.body as? String else { return [] }
        return ContentBlocker.shared.genericSelectors(payload: payload, pageURL: url, exceptions: blocking?.exceptions ?? [])
    }

    private func showError(_ error: NSError, url: URL) {
        let host = Self.escaped(url.host ?? url.absoluteString)
        let message = Self.escaped(error.localizedDescription)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <title>Can’t open this page</title><style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;font:15px/1.45 -apple-system,system-ui;background:Canvas;color:CanvasText}
        main{max-width:30rem;padding:24px}h1{margin:0 0 8px;font-size:22px;font-weight:600}p{margin:0;opacity:.72}
        </style></head><body><main><h1>Can’t open this page</h1><p><strong>\(host)</strong>: \(message)</p></main></body></html>
        """
        errorPageURL = url
        errorPage = nativeView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
    }

    /// A load that ended, or a page that replaced it, leaves its sign-in
    /// with nothing to answer.
    private func dismissSignIn() {
        guard let alert = signIn, let parent = alert.window.sheetParent else { return }
        signIn = nil
        parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func navigationKind(_ type: WKNavigationType) -> NavigationKind {
        switch type {
        case .linkActivated: .link
        case .formSubmitted, .formResubmitted: .form
        case .backForward: .history
        case .reload: .reload
        default: .other
        }
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Schemes WebKit renders itself.
    private static let pageSchemes: Set<String> = ["about", "blob", "data", "file"]


    // MARK: - Downloads

    private func adopt(_ download: WKDownload) {
        nextDownload += 1
        downloadIDs[ObjectIdentifier(download)] = nextDownload
        downloads[nextDownload] = download
        download.delegate = self
    }

    /// A download that was refused before it started.
    private func forget(_ download: WKDownload) {
        guard let identifier = downloadIDs.removeValue(forKey: ObjectIdentifier(download)) else { return }
        downloads.removeValue(forKey: identifier)
    }

    private func observeProgress(_ download: WKDownload, identifier: UInt32, destination: URL) {
        downloadDestinations[identifier] = destination
        downloadProgress[identifier] = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.reportProgress(identifier) }
        }
        reportDownload(identifier)
    }

    /// A few updates a second are enough for the downloads panel.
    private func reportProgress(_ identifier: UInt32) {
        guard Date().timeIntervalSince(downloadReportedAt[identifier] ?? .distantPast) > 0.25 else { return }
        downloadReportedAt[identifier] = Date()
        reportDownload(identifier)
    }

    private func reportDownload(_ identifier: UInt32, complete: Bool = false, cancelled: Bool = false, interrupted: Bool = false) {
        guard let download = downloads[identifier] else { return }
        let received = download.progress.completedUnitCount
        let total = complete ? max(download.progress.totalUnitCount, received) : download.progress.totalUnitCount
        let path = downloadDestinations[identifier]?.path ?? ""
        if complete || cancelled || interrupted {
            downloads.removeValue(forKey: identifier)
            downloadIDs.removeValue(forKey: ObjectIdentifier(download))
            downloadDestinations.removeValue(forKey: identifier)
            downloadProgress.removeValue(forKey: identifier)
            downloadReportedAt.removeValue(forKey: identifier)
            cancelledDownloads.remove(identifier)
        }
        delegate?.page(self, didUpdateDownload: identifier, fullPath: path, receivedBytes: received, totalBytes: total,
                       percent: complete ? 100 : total > 0 ? Int(received * 100 / total) : -1,
                       complete: complete, cancelled: cancelled, interrupted: interrupted)
    }

    private func chooseDestination(_ suggestedFilename: String, done: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DownloadNaming.sanitized(suggestedFilename)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return done(nil) }
            // The panel asked before replacing a file, and WebKit will not
            // write over one.
            try? FileManager.default.removeItem(at: url)
            done(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

/// A frame's first edit by a person. The discard probe reads only the main
/// frame, so this keeps the page awake until it navigates.
@MainActor
private final class FrameEdits: NSObject, WKScriptMessageHandler {
    weak var page: WebKitPage?

    init(page: WebKitPage) { self.page = page }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !message.frameInfo.isMainFrame else { return }
        page?.noteFrameEdit()
    }
}

/// WKUserContentController keeps its handlers alive; the page must not be one.
@MainActor
private final class CosmeticsReplies: NSObject, WKScriptMessageHandlerWithReply {
    weak var page: WebKitPage?

    init(page: WebKitPage) { self.page = page }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        replyHandler(page?.genericSelectors(message) ?? [], nil)
    }
}

extension WebKitPage: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let destination = action.request.url else { return decisionHandler(.cancel) }
        if action.shouldPerformDownload { return decisionHandler(.download) }
        // A new window is decided when WebKit asks to create it.
        guard let frame = action.targetFrame else { return decisionHandler(.allow) }

        // Command-click and middle-click open a link in a new tab.
        if frame.isMainFrame, action.navigationType == .linkActivated,
           action.modifierFlags.contains(.command) || action.buttonNumber == 2 {
            decisionHandler(.cancel)
            delegate?.page(self, requestedPopup: destination)
            return
        }

        // The error page for a failed load was reviewed as that load.
        if frame.isMainFrame, let errorPageURL {
            self.errorPageURL = nil
            if destination == errorPageURL { return decisionHandler(.allow) }
        }

        var kind = Self.navigationKind(action.navigationType)
        var source = committedURL
        // Subframes load while a restarted page waits, and must not clear it.
        if frame.isMainFrame {
            if let restarted, restarted.url == destination {
                kind = restarted.kind
                source = restarted.source
            }
            restarted = nil
        }

        // Tracking parameters never reach a page, whether or not blocking is
        // on. Only GET restarts without replaying a body.
        if Self.isWeb(destination), (action.request.httpMethod ?? "GET") == "GET",
           let clean = ContentBlocker.shared.cleanAddress(destination, page: frame.isMainFrame ? nil : url,
                                                          subframe: !frame.isMainFrame) {
            decisionHandler(.cancel)
            if frame.isMainFrame {
                // A redirect restarted at its clean address is still reviewed
                // as one.
                restarted = provisional ? (clean, .redirect, chainStart) : (clean, kind, source)
                nativeView.load(URLRequest(url: clean))
            } else {
                let literal = String(decoding: (try? JSONSerialization.data(withJSONObject: clean.absoluteString,
                                                                             options: .fragmentsAllowed)) ?? Data(), as: UTF8.self)
                nativeView.evaluateJavaScript("location.replace(\(literal))", in: frame, in: .defaultClient)
            }
            return
        }
        guard frame.isMainFrame else { return decisionHandler(.allow) }

        let proceed: () -> Void = { [weak self] in
            guard let self else { return decisionHandler(.cancel) }
            // Mail, phone, and app links belong to the app that handles them;
            // the person has already confirmed leaving the web.
            if !Self.isWeb(destination), !Self.pageSchemes.contains(destination.scheme?.lowercased() ?? "") {
                decisionHandler(.cancel)
                NSWorkspace.shared.open(destination)
                return
            }
            self.allowedURL = destination
            self.certificateErrorReported = false
            self.prepareDocument(for: destination)
            decisionHandler(.allow)
        }
        let reviewing = delegate?.page(self, decideNavigationTo: destination, source: source, kind: kind) { allow in
            if allow { proceed() } else { decisionHandler(.cancel) }
        } ?? false
        if !reviewing { proceed() }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased().hasPrefix("attachment") == true
        if !response.canShowMIMEType || attachment { return decisionHandler(.download) }
        // WebKit asks about each redirect before it reports one, so the chain
        // as a whole is reviewed here, from where it began.
        guard response.isForMainFrame, redirected, let start = chainStart,
              let destination = response.response.url, Self.isWeb(destination) else { return decisionHandler(.allow) }
        let chain: [NavigationReview.Reason] = [.crossSiteRedirect, .insecureDowngrade]
        let review = NavigationSafety.review(destination: destination, source: start, kind: .redirect)
        guard review.reasons.contains(where: chain.contains) else { return decisionHandler(.allow) }
        let reviewing = delegate?.page(self, decideNavigationTo: destination, source: start, kind: .redirect) { allow in
            decisionHandler(allow ? .allow : .cancel)
        } ?? false
        if !reviewing { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        chainStart = allowedURL
        provisional = true
        redirected = false
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        redirected = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        provisional = false
        redirected = false
        frameEdited = false
        dismissSignIn()
        committedURL = webView.url
        delegate?.pageDidCommit(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let errorPage, errorPage === navigation {
            self.errorPage = nil
            return
        }
        delegate?.pageDidFinish(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain, error.code != NSURLErrorCancelled else { return }
        delegate?.page(self, didFail: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        provisional = false
        redirected = false
        dismissSignIn()
        let error = error as NSError
        // WebKit's own codes mean a policy, a download, or a plug-in took the load.
        guard error.domain == NSURLErrorDomain, ![NSURLErrorCancelled, NSURLErrorUnsupportedURL].contains(error.code) else { return }
        let failed = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? allowedURL
        let certificate = [NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                           NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid]
        if certificate.contains(error.code), let failed, !certificateErrorReported {
            certificateErrorReported = true
            delegate?.page(self, didRejectCertificateAt: failed, error: error.localizedDescription)
        }
        delegate?.page(self, didFail: error.localizedDescription)
        if let failed { showError(error, url: failed) }
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Task {
            let response = await BrowserPrompts.authenticationResponse(for: challenge, window: window) { [weak self] alert in
                self?.signIn = alert
            }
            signIn = nil
            completionHandler(response.0, response.1)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        delegate?.pageWebContentProcessDidTerminate(self)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adopt(download)
    }
}

extension WebKitPage: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        guard let identifier = downloadIDs[ObjectIdentifier(download)],
              let url = download.originalRequest?.url ?? response.url, let delegate else {
            forget(download)
            return completionHandler(nil)
        }
        delegate.page(self, decideDownloadFrom: committedURL, to: url) { [weak self] allow in
            guard let self, allow, self.delegate != nil else {
                self?.forget(download)
                return completionHandler(nil)
            }
            self.delegate?.page(self, didStartDownload: identifier, url: url, suggestedFilename: suggestedFilename)
            self.chooseDestination(suggestedFilename) { destination in
                // The tab may have closed while the panel was up.
                guard let destination, self.delegate != nil else {
                    completionHandler(nil)
                    self.reportDownload(identifier, cancelled: true)
                    return
                }
                completionHandler(destination)
                self.observeProgress(download, identifier: identifier, destination: destination)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let identifier = downloadIDs[ObjectIdentifier(download)] else { return }
        reportDownload(identifier, complete: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let identifier = downloadIDs[ObjectIdentifier(download)] else { return }
        if cancelledDownloads.contains(identifier) {
            reportDownload(identifier, cancelled: true)
        } else {
            reportDownload(identifier, interrupted: true)
        }
    }
}

extension WebKitPage: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, url.absoluteString != "about:blank", !url.absoluteString.isEmpty {
            delegate?.page(self, requestedPopup: url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let kind: WebsitePermissionKind
        switch type {
        case .camera: kind = .camera
        case .microphone: kind = .microphone
        case .cameraAndMicrophone: kind = .cameraAndMicrophone
        @unknown default: return decisionHandler(.deny)
        }
        decidePermission(origin, kind: kind, decisionHandler: decisionHandler)
    }

    @available(macOS 27.0, *)
    func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decidePermission(origin, kind: .location, decisionHandler: decisionHandler)
    }

    private func decidePermission(_ origin: WKSecurityOrigin, kind: WebsitePermissionKind,
                                  decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        guard let delegate else { return decisionHandler(.deny) }
        delegate.page(self, decidePermissionFor: BrowserPrompts.origin(origin), kind: kind) { allow in
            decisionHandler(allow ? .grant : .deny)
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        delegate?.pageWillChooseFiles(self)
        Task {
            let script = "document.activeElement instanceof HTMLInputElement ? document.activeElement.accept : ''"
            let accepted = try? await nativeView.callAsyncJavaScript("return \(script);", in: frame, contentWorld: .defaultClient) as? String
            let urls = await BrowserPrompts.chooseFiles(parameters, accepting: accepted, window: window)
            delegate?.pageDidChooseFiles(self)
            completionHandler(urls)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        Task {
            await BrowserPrompts.showAlert(message: message, origin: BrowserPrompts.origin(frame), window: window)
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        Task {
            completionHandler(await BrowserPrompts.showConfirm(message: message, origin: BrowserPrompts.origin(frame), window: window))
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        Task {
            completionHandler(await BrowserPrompts.showPrompt(message: prompt, defaultText: defaultText,
                                                              origin: BrowserPrompts.origin(frame), window: window))
        }
    }
}
