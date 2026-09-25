import AppKit

extension ChromiumPage: PageJavaScriptEvaluating {
    func interlinkedEvaluate(_ body: String, arguments: [String: Any], userGesture: Bool) async throws -> Any? {
        let declarations = try arguments.map { key, value -> String in
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            guard let json = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            return "const \(key)=\(json);"
        }.joined()
        return try await evaluateJavaScript("(async()=>{\(declarations)\(body)})()", userGesture: userGesture)
    }
}

@MainActor
protocol ChromiumPageDelegate: AnyObject {
    func chromiumPageDidCreate(_ page: ChromiumPage)
    func chromiumPageDidChange(_ page: ChromiumPage)
    func chromiumPageDidCommit(_ page: ChromiumPage)
    func chromiumPageDidFinish(_ page: ChromiumPage)
    func chromiumPage(_ page: ChromiumPage, didFail message: String)
    func chromiumPage(_ page: ChromiumPage, requestedPopup url: URL, userGesture: Bool)
    func chromiumPage(_ page: ChromiumPage, didStartDownload identifier: UInt32, url: URL, suggestedFilename: String)
    func chromiumPage(_ page: ChromiumPage, didUpdateDownload identifier: UInt32, fullPath: String, receivedBytes: Int64, totalBytes: Int64, percent: Int, complete: Bool, cancelled: Bool, interrupted: Bool)
    func chromiumPage(_ page: ChromiumPage, didBlockRequests count: Int)
    func chromiumPage(
        _ page: ChromiumPage,
        decideNavigationTo destination: URL,
        source: URL?,
        kind: NavigationKind,
        completion: @escaping (Bool) -> Void
    ) -> Bool
    func chromiumPage(
        _ page: ChromiumPage,
        decidePermissionFor origin: String,
        kind: WebsitePermissionKind,
        completion: @escaping (Bool) -> Void
    )
    func chromiumPage(
        _ page: ChromiumPage,
        decideDownloadFrom source: URL?,
        to destination: URL,
        completion: @escaping (Bool) -> Void
    )
    func chromiumPage(_ page: ChromiumPage, didRejectCertificateAt url: URL, error: String)
    func chromiumPageWebContentProcessDidTerminate(_ page: ChromiumPage)
    func chromiumPageDidClose(_ page: ChromiumPage)
}

/// Engine-owned page object used by the rest of Interlinked. SwiftUI receives
/// only `nativeView`; navigation and page operations stay behind this seam.
@MainActor
final class ChromiumPage: NSObject, ILChromiumViewDelegate {
    let nativeView: ILChromiumView
    weak var delegate: ChromiumPageDelegate?

    var url: URL? { nativeView.url }
    var title: String? {
        let value = nativeView.title
        return value.isEmpty ? nil : value
    }
    var isLoading: Bool { nativeView.isLoading }
    var canGoBack: Bool { nativeView.canGoBack }
    var canGoForward: Bool { nativeView.canGoForward }
    var window: NSWindow? { nativeView.window }
    var forcedDarkMode: Bool {
        get { nativeView.forcedDarkMode }
        set { nativeView.forcedDarkMode = newValue }
    }
    var rendersDark: Bool { forcedDarkMode }
    /// Blurs sensitive text in every document this page loads.
    var sharingScreenShield = false {
        didSet {
            guard sharingScreenShield != oldValue else { return }
            nativeView.setDocumentStartScript(sharingScreenShield ? SharingScreenShield.script : nil,
                                              stopScript: SharingScreenShield.stopScript)
        }
    }

    init(initialURL: URL) {
        nativeView = ILChromiumView(frame: .zero, initialURL: initialURL)
        super.init()
        nativeView.delegate = self
    }

    func load(_ request: URLRequest) {
        guard let url = request.url else { return }
        nativeView.navigate(to: url)
    }

    func load(_ url: URL) {
        nativeView.navigate(to: url)
    }

    func goBack() { nativeView.goBack() }
    func goForward() { nativeView.goForward() }
    func reload() { nativeView.reload() }
    func reloadFromOrigin() { nativeView.reloadIgnoringCache() }
    func stopLoading() { nativeView.stopLoading() }
    func focus() { nativeView.focusBrowser() }
    func close() { nativeView.closeBrowser() }
    func cancelDownload(_ identifier: UInt32) { nativeView.cancelDownload(identifier) }

    func evaluateJavaScript(_ script: String, userGesture: Bool = false) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            nativeView.evaluateJavaScript(script, userGesture: userGesture) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result) }
            }
        }
    }

    func evaluateJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        nativeView.evaluateJavaScript(script) { result, error in completion?(result, error) }
    }

    func find(_ text: String, backwards: Bool, findNext: Bool = true, completion: @escaping (Bool) -> Void) {
        nativeView.findText(text, backwards: backwards, findNext: findNext, completion: completion)
    }

    func stopFinding() { nativeView.stopFinding() }

    func snapshot(width: CGFloat = 600) -> NSImage? {
        guard nativeView.bounds.width > 0, nativeView.bounds.height > 0 else { return nil }
        let scale = min(1, width / nativeView.bounds.width)
        let source = nativeView.bounds
        guard let rep = nativeView.bitmapImageRepForCachingDisplay(in: source) else { return nil }
        nativeView.cacheDisplay(in: source, to: rep)
        let image = NSImage(size: NSSize(width: source.width * scale, height: source.height * scale))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: rep.cgImage!, size: source.size).draw(
            in: NSRect(origin: .zero, size: image.size),
            from: NSRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }

    func chromiumViewDidCreateBrowser(_ view: ILChromiumView) {
        delegate?.chromiumPageDidCreate(self)
    }

    func chromiumView(_ view: ILChromiumView, didChange url: URL?) {
        delegate?.chromiumPageDidChange(self)
    }

    func chromiumView(_ view: ILChromiumView, didChangeTitle title: String) {
        delegate?.chromiumPageDidChange(self)
    }

    func chromiumView(
        _ view: ILChromiumView,
        didChangeLoading isLoading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        delegate?.chromiumPageDidChange(self)
    }

    func chromiumViewDidCommitNavigation(_ view: ILChromiumView) {
        delegate?.chromiumPageDidCommit(self)
    }

    func chromiumViewDidFinishNavigation(_ view: ILChromiumView) {
        delegate?.chromiumPageDidFinish(self)
    }

    func chromiumView(_ view: ILChromiumView, didFailNavigation message: String) {
        delegate?.chromiumPage(self, didFail: message)
    }

    func chromiumView(_ view: ILChromiumView, requestedPopupURL url: URL, userGesture: Bool) {
        delegate?.chromiumPage(self, requestedPopup: url, userGesture: userGesture)
    }

    func chromiumView(_ view: ILChromiumView, didStartDownload identifier: UInt32, url: URL, suggestedFilename: String) {
        delegate?.chromiumPage(self, didStartDownload: identifier, url: url, suggestedFilename: suggestedFilename)
    }

    func chromiumView(_ view: ILChromiumView, didUpdateDownload identifier: UInt32, fullPath: String, receivedBytes: Int64, totalBytes: Int64, percent: Int, complete: Bool, cancelled: Bool, interrupted: Bool) {
        delegate?.chromiumPage(self, didUpdateDownload: identifier, fullPath: fullPath, receivedBytes: receivedBytes, totalBytes: totalBytes, percent: percent, complete: complete, cancelled: cancelled, interrupted: interrupted)
    }

    func chromiumView(_ view: ILChromiumView, didBlockRequests count: Int) {
        delegate?.chromiumPage(self, didBlockRequests: count)
    }

    func chromiumView(
        _ view: ILChromiumView,
        decideNavigationTo url: URL,
        sourceURL: URL?,
        kind: ILNavigationKind,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard let delegate else { return false }
        return delegate.chromiumPage(
            self,
            decideNavigationTo: url,
            source: sourceURL,
            kind: kind.navigationKind,
            completion: completion
        )
    }

    func chromiumView(
        _ view: ILChromiumView,
        decidePermissionForOrigin origin: String,
        kind: ILWebsitePermissionKind,
        completion: @escaping (Bool) -> Void
    ) {
        guard let delegate, let kind = kind.websitePermissionKind else {
            completion(false)
            return
        }
        delegate.chromiumPage(self, decidePermissionFor: origin, kind: kind, completion: completion)
    }

    func chromiumView(
        _ view: ILChromiumView,
        decideDownloadFrom sourceURL: URL?,
        to url: URL,
        completion: @escaping (Bool) -> Void
    ) {
        guard let delegate else {
            completion(false)
            return
        }
        delegate.chromiumPage(self, decideDownloadFrom: sourceURL, to: url, completion: completion)
    }

    func chromiumView(_ view: ILChromiumView, didRejectCertificateAt url: URL, error: String) {
        delegate?.chromiumPage(self, didRejectCertificateAt: url, error: error)
    }

    func chromiumViewWebContentProcessDidTerminate(_ view: ILChromiumView) {
        delegate?.chromiumPageWebContentProcessDidTerminate(self)
    }

    func chromiumViewDidClose(_ view: ILChromiumView) {
        delegate?.chromiumPageDidClose(self)
    }
}

private extension ILNavigationKind {
    var navigationKind: NavigationKind {
        switch self {
        case .link: return .link
        case .form: return .form
        case .redirect: return .redirect
        case .reload: return .reload
        case .history: return .history
        default: return .other
        }
    }
}

private extension ILWebsitePermissionKind {
    var websitePermissionKind: WebsitePermissionKind? {
        switch self {
        case .camera: return .camera
        case .microphone: return .microphone
        case .cameraAndMicrophone: return .cameraAndMicrophone
        case .location: return .location
        default: return nil
        }
    }
}
