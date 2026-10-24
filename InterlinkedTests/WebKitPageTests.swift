import WebKit
import XCTest

/// Drives `WebKitPage` against a loopback server: the navigation reviews it
/// asks for, tracking parameters, redirect chains, error pages, popups, dark
/// pages, and content blocking.
@MainActor
final class WebKitPageTests: XCTestCase {
    private var server: TestHTTPServer!
    private var window: NSWindow!

    override func setUp() async throws {
        server = try await TestHTTPServer.start()
        server.route("/page", .html("<title>Page</title><p>Page"))
        ContentBlocker.shared.setEnabled(false, disabledSites: [])
        // Pages in a visible window lay out and run animation frames. It is
        // transparent, so running the tests shows nothing on screen.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFront(nil)
    }

    override func tearDown() async throws {
        server.stop()
        window.close()
        ContentBlocker.shared.setEnabled(false, disabledSites: [])
    }

    func testTrackingParametersAreStrippedBeforeTheReview() async throws {
        let (page, delegate) = makePage()
        page.load(server.url("/page?utm_source=news&id=5&gclid=abc"))
        try await waitFor { delegate.finished.contains(self.server.url("/page?id=5")) }
        XCTAssertEqual(delegate.reviews.map(\.destination), [server.url("/page?id=5")])
    }

    func testCrossSiteRedirectIsReviewedFromWhereTheChainStarted() async throws {
        server.route("/hop", .redirect(to: server.url("/page", host: "localhost")))
        let (page, delegate) = makePage()
        try await followLink(to: "/hop", in: page, delegate)
        try await waitFor { delegate.finished.contains(self.server.url("/page", host: "localhost")) }
        let redirects = delegate.reviews.filter { $0.kind == .redirect }
        XCTAssertEqual(redirects, [.init(destination: server.url("/page", host: "localhost"), source: server.url("/hop"), kind: .redirect)])
    }

    func testSameSiteRedirectIsNotReviewedAsARedirect() async throws {
        server.route("/hop", .redirect(to: server.url("/page")))
        let (page, delegate) = makePage()
        try await followLink(to: "/hop", in: page, delegate)
        try await waitFor { delegate.finished.contains(self.server.url("/page")) }
        XCTAssertFalse(delegate.reviews.contains { $0.kind == .redirect }, "\(delegate.reviews)")
    }

    func testDeclinedRedirectLeavesThePageWhereItWas() async throws {
        server.route("/hop", .redirect(to: server.url("/page", host: "localhost")))
        let (page, delegate) = makePage()
        delegate.allows = { $0.kind != .redirect }
        try await followLink(to: "/hop", in: page, delegate)
        try await waitFor { delegate.reviews.contains { $0.kind == .redirect } }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(page.url, server.url("/links"))
        XCTAssertFalse(delegate.finished.contains(server.url("/page", host: "localhost")))
    }

    func testScriptNavigationThatRedirectsToAnotherSiteIsReviewed() async throws {
        // WebKit calls a page's own location change `other`, like an address
        // Interlinked opens, but the page started it.
        server.route("/hop", .redirect(to: server.url("/page", host: "localhost")))
        let (page, delegate) = makePage()
        page.load(server.url("/page"))
        try await waitFor { delegate.finished.contains(self.server.url("/page")) }
        _ = try await page.evaluateJavaScript("location.href = '/hop'")
        try await waitFor { delegate.finished.contains(self.server.url("/page", host: "localhost")) }
        XCTAssertTrue(delegate.reviews.contains(.init(destination: server.url("/page", host: "localhost"),
                                                      source: server.url("/hop"), kind: .redirect)), "\(delegate.reviews)")
    }

    func testOpenedAddressThatRedirectsToAnotherSiteIsNotReviewedAsARedirect() async throws {
        // Typed, or opened from another app: the person chose the address,
        // and links from mail often bounce through a tracker on another site.
        server.route("/hop", .redirect(to: server.url("/page?utm_source=mail&id=3", host: "localhost")))
        let (page, delegate) = makePage()
        page.load(server.url("/hop"))
        try await waitFor { delegate.finished.contains(self.server.url("/page?id=3", host: "localhost")) }
        XCTAssertFalse(delegate.reviews.contains { $0.kind == .redirect }, "\(delegate.reviews)")
    }

    func testRedirectRestartedWithoutTrackingParametersIsStillReviewedAsARedirect() async throws {
        server.route("/hop", .redirect(to: server.url("/page?utm_source=mail&id=7", host: "localhost")))
        let (page, delegate) = makePage()
        try await followLink(to: "/hop", in: page, delegate)
        let clean = server.url("/page?id=7", host: "localhost")
        try await waitFor { delegate.finished.contains(clean) }
        XCTAssertTrue(delegate.reviews.contains(.init(destination: clean, source: server.url("/hop"), kind: .redirect)),
                      "\(delegate.reviews)")
        XCTAssertFalse(delegate.reviews.contains { $0.destination.query?.contains("utm_source") == true })
    }

    func testSubframeLoadDuringARestartKeepsTheRestartedReview() async throws {
        let (page, delegate) = makePage()
        page.load(server.url("/page"))
        try await waitFor { delegate.finished.contains(self.server.url("/page")) }
        let tagged = server.url("/page?utm_source=mail&id=9"), clean = server.url("/page?id=9")
        var decisions: [WKNavigationActionPolicy] = []
        // A link with tracking parameters restarts at its clean address, and a
        // subframe loads before WebKit asks about the restart.
        page.webView(page.nativeView, decidePolicyFor: FakeAction(tagged, in: FakeFrame(main: true), type: .linkActivated)) {
            decisions.append($0)
        }
        page.webView(page.nativeView, decidePolicyFor: FakeAction(server.url("/frame"), in: FakeFrame(main: false), type: .other)) {
            decisions.append($0)
        }
        XCTAssertEqual(decisions, [.cancel, .allow])
        try await waitFor { delegate.finished.contains(clean) }
        XCTAssertTrue(delegate.reviews.contains(.init(destination: clean, source: server.url("/page"), kind: .link)),
                      "\(delegate.reviews)")
    }

    func testFailedLoadShowsAnErrorPageWithoutAnotherReview() async throws {
        server.route("/drop", .drop)
        let closed = server.url("/drop")
        let (page, delegate) = makePage()
        page.load(closed)
        try await waitFor { page.title == "Can’t open this page" }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(delegate.reviews.filter { $0.destination == closed }.count, 1, "\(delegate.reviews)")
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertFalse(delegate.finished.contains(closed), "The error page is not a page the rest of Interlinked reads")
        XCTAssertEqual(page.url, closed)
    }

    func testLinkToANewWindowBecomesARequestedPopup() async throws {
        server.route("/links", .html("<a id=a target=_blank href='/page?from=link'>Open</a>"))
        let (page, delegate) = makePage()
        page.load(server.url("/links"))
        try await waitFor { delegate.finished.contains(self.server.url("/links")) }
        _ = try await page.evaluateJavaScript("document.getElementById('a').click()")
        try await waitFor { !delegate.popups.isEmpty }
        XCTAssertEqual(delegate.popups, [server.url("/page?from=link")])
        XCTAssertEqual(page.url, server.url("/links"))
    }

    func testDarkPageInvertsOnlyPagesWithoutTheirOwnDarkTheme() async throws {
        server.route("/light", .html("<p>Light page"))
        server.route("/dark", .html("<body style='background:#111;color:#eee'><p>Dark page</body>"))
        server.route("/scheme", .html("<meta name=color-scheme content=dark><p>Dark by color scheme"))
        let (page, delegate) = makePage()
        page.forcedDarkMode = true
        for (path, inverted) in [("/light", true), ("/dark", false), ("/scheme", false), ("/light", true)] {
            page.load(server.url(path))
            try await waitFor { delegate.finished.last == self.server.url(path) }
            try await waitFor(message: path) {
                let filter = (try? await page.evaluateJavaScript("getComputedStyle(document.documentElement).filter")) as? String
                return filter?.contains("invert") == inverted
            }
        }
        page.forcedDarkMode = false
        try await waitFor(message: "off") {
            let filter = (try? await page.evaluateJavaScript("getComputedStyle(document.documentElement).filter")) as? String
            return filter == "none"
        }
    }

    func testContentRuleListsBlockMatchingRequestsUnlessTheSiteIsAllowed() async throws {
        server.route("/scripts", .html("<script src='/allowed.js'></script><script src='/blocked.js'></script>"))
        server.route("/allowed.js", .script("window.allowedRan = true"))
        server.route("/blocked.js", .script("window.blockedRan = true"))
        let built = try XCTUnwrap(BlockerEngine.build(lists: ["/blocked.js\n"], trusted: IndexSet(), resourcesJSON: "[]"))
        let compiled = await ContentBlocker.shared.compile(built.ruleLists)
        XCTAssertTrue(compiled)
        ContentBlocker.shared.install(built.engine)
        ContentBlocker.shared.setEnabled(true, disabledSites: [])

        let (page, delegate) = makePage()
        page.load(server.url("/scripts"))
        try await waitFor { delegate.finished.contains(self.server.url("/scripts")) }
        let ran = try await page.evaluateJavaScript("[!!window.allowedRan, !!window.blockedRan]") as? [Bool]
        XCTAssertEqual(ran, [true, false])

        ContentBlocker.shared.setEnabled(true, disabledSites: ["127.0.0.1"])
        page.refreshContentBlocking()
        delegate.finished.removeAll()
        page.reload()
        try await waitFor { delegate.finished.contains(self.server.url("/scripts")) }
        let unblocked = try await page.evaluateJavaScript("[!!window.allowedRan, !!window.blockedRan]") as? [Bool]
        XCTAssertEqual(unblocked, [true, true])
    }

    func testRestoringRuleListsTakesTheLatestCompile() async throws {
        let list = #"[{"trigger":{"url-filter":"example-ad"},"action":{"type":"block"}}]"#
        let first = await ContentBlocker.shared.compile([list, list])
        XCTAssertTrue(first)
        XCTAssertEqual(ContentBlocker.shared.ruleLists.count, 2)
        let second = await ContentBlocker.shared.compile([list])
        XCTAssertTrue(second)
        let restored = await ContentBlocker.shared.restoreRuleLists()
        XCTAssertTrue(restored)
        XCTAssertEqual(ContentBlocker.shared.ruleLists.count, 1)
    }

    func testFailedCompileKeepsThePreviousLists() async throws {
        let list = #"[{"trigger":{"url-filter":"example-ad"},"action":{"type":"block"}}]"#
        let compiled = await ContentBlocker.shared.compile([list, list])
        XCTAssertTrue(compiled)
        let broken = await ContentBlocker.shared.compile([list, "[{\"trigger\":{}}]"])
        XCTAssertFalse(broken)
        XCTAssertEqual(ContentBlocker.shared.ruleLists.count, 2)
        let restored = await ContentBlocker.shared.restoreRuleLists()
        XCTAssertTrue(restored)
        XCTAssertEqual(ContentBlocker.shared.ruleLists.count, 2)
    }

    func testStoredRuleListIdentifiersRoundTrip() {
        let list = StoredRuleList(generation: 1_777_000_000_123, index: 1, count: 3)
        XCTAssertEqual(StoredRuleList(list.identifier), list)
        XCTAssertNil(StoredRuleList("interlinked-blocker-0"), "The first WebKit build's lists are stale")
        XCTAssertNil(StoredRuleList("interlinked-blocker-5-3-3"))
        XCTAssertNil(StoredRuleList("someone-else-1-0-1"))
    }

    func testDiscardProbeCountsOnlyFieldsAPersonChanged() async throws {
        server.route("/form", .html("""
        <input id=name><input type=radio name=r id=a checked><input type=radio name=r id=b>
        <select id=s><option>a<option>b</select>
        <script>
        document.getElementById('b').checked = true;
        document.getElementById('s').selectedIndex = 1;
        const name = document.getElementById('name');
        name.value = 'set by the page';
        name.dispatchEvent(new Event('input', {bubbles: true}));
        </script>
        """))
        let (page, delegate) = makePage()
        page.load(server.url("/form"))
        try await waitFor { delegate.finished.contains(self.server.url("/form")) }
        let untouched = await discardProbe(page)
        XCTAssertEqual(untouched?.safe, true, "Values the page set itself are nobody's unsaved work")
        let visible = try await page.evaluateJavaScript("typeof globalThis.__interlinkedEdited") as? String
        XCTAssertEqual(visible, "undefined", "The page can neither read nor fake the record")

        // A person's edit, as the recorder would have seen it.
        _ = try await page.nativeView.callAsyncJavaScript(
            "const name = document.getElementById('name'); globalThis.__interlinkedEdited.add(name); name.value = 'typed'",
            contentWorld: WebKitPage.editsWorld)
        let edited = await discardProbe(page)
        XCTAssertEqual(edited?.safe, false)
    }

    func testAnEditInAFrameKeepsThePageAwakeUntilItNavigates() async throws {
        server.route("/framed", .html("<iframe src='/inner'></iframe>"))
        server.route("/inner", .html("<input id=field>"))
        let (page, delegate) = makePage()
        page.load(server.url("/framed"))
        try await waitFor { delegate.finished.contains(self.server.url("/framed")) }
        let untouched = await discardProbe(page)
        XCTAssertEqual(untouched?.safe, true)

        // What a frame's recorder reports after a person's first edit there.
        page.noteFrameEdit()
        let edited = await discardProbe(page)
        XCTAssertEqual(edited?.safe, false)

        page.load(server.url("/page"))
        try await waitFor { delegate.finished.contains(self.server.url("/page")) }
        let navigated = await discardProbe(page)
        XCTAssertEqual(navigated?.safe, true)
    }

    func testTheRecorderReportsFrameEditsToItsOwnHandler() {
        XCTAssertTrue(BrowserDiscardProbe.recordEdits.contains("messageHandlers?.\(BrowserDiscardProbe.frameEditHandler)?.postMessage"))
    }

    private func discardProbe(_ page: WebKitPage) async -> BrowserDiscardProbe? {
        await withCheckedContinuation { continuation in
            page.evaluateDiscardProbe { continuation.resume(returning: $0) }
        }
    }

    /// Starts a navigation the way a page does: from a link it shows.
    private func followLink(to path: String, in page: WebKitPage, _ delegate: RecordingPageDelegate) async throws {
        server.route("/links", .html("<a id=go href='\(path)'>Go</a>"))
        page.load(server.url("/links"))
        try await waitFor { delegate.finished.contains(self.server.url("/links")) }
        _ = try await page.evaluateJavaScript("document.getElementById('go').click()")
    }

    private func makePage() -> (WebKitPage, RecordingPageDelegate) {
        let page = WebKitPage(initialURL: URL(string: "about:blank")!)
        let delegate = RecordingPageDelegate()
        page.delegate = delegate
        page.nativeView.frame = window.contentView!.bounds
        window.contentView!.addSubview(page.nativeView)
        addTeardownBlock { @MainActor in
            page.delegate = nil
            page.close()
            page.nativeView.removeFromSuperview()
        }
        return (page, delegate)
    }

    private func waitFor(_ timeout: Duration = .seconds(10), message: String = "",
                         _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting \(message)") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

/// A navigation as WebKit would describe it, for orderings a live page
/// cannot produce on demand. WebKit's `dealloc` for these classes frees
/// storage only its own initializers set up, so fakes live as long as the
/// test process.
@MainActor
private var fakes: [NSObject] = []

private final class FakeAction: WKNavigationAction {
    private let url: URL
    private let frame: WKFrameInfo
    private let type: WKNavigationType

    @MainActor
    init(_ url: URL, in frame: WKFrameInfo, type: WKNavigationType) {
        self.url = url
        self.frame = frame
        self.type = type
        super.init()
        fakes.append(self)
    }

    override var request: URLRequest { URLRequest(url: url) }
    override var targetFrame: WKFrameInfo? { frame }
    override var navigationType: WKNavigationType { type }
    override var shouldPerformDownload: Bool { false }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var buttonNumber: Int { 0 }
}

private final class FakeFrame: WKFrameInfo {
    private let main: Bool

    @MainActor
    init(main: Bool) {
        self.main = main
        super.init()
        fakes.append(self)
    }

    override var isMainFrame: Bool { main }
}

/// Records what a page asks of Interlinked and answers every review with
/// `allows`.
@MainActor
private final class RecordingPageDelegate: WebKitPageDelegate {
    struct Review: Equatable, CustomStringConvertible {
        let destination: URL
        let source: URL?
        let kind: NavigationKind
        var description: String { "\(kind) \(destination) from \(source?.absoluteString ?? "nil")" }
    }

    var allows: (Review) -> Bool = { _ in true }
    var reviews: [Review] = []
    var finished: [URL] = []
    var failures: [String] = []
    var popups: [URL] = []

    func pageDidChange(_ page: WebKitPage) {}
    func pageDidCommit(_ page: WebKitPage) {}
    func pageDidFinish(_ page: WebKitPage) { page.url.map { finished.append($0) } }
    func page(_ page: WebKitPage, didFail message: String) { failures.append(message) }
    func page(_ page: WebKitPage, requestedPopup url: URL) { popups.append(url) }
    func page(_ page: WebKitPage, didStartDownload identifier: UInt32, url: URL, suggestedFilename: String) {}
    func page(_ page: WebKitPage, didUpdateDownload identifier: UInt32, fullPath: String, receivedBytes: Int64,
              totalBytes: Int64, percent: Int, complete: Bool, cancelled: Bool, interrupted: Bool) {}

    func page(_ page: WebKitPage, decideNavigationTo destination: URL, source: URL?, kind: NavigationKind,
              completion: @escaping (Bool) -> Void) -> Bool {
        guard destination.scheme != "about" else { return false }
        let review = Review(destination: destination, source: source, kind: kind)
        reviews.append(review)
        completion(allows(review))
        return true
    }

    func page(_ page: WebKitPage, decidePermissionFor origin: String, kind: WebsitePermissionKind,
              completion: @escaping (Bool) -> Void) { completion(false) }
    func page(_ page: WebKitPage, decideDownloadFrom source: URL?, to destination: URL,
              completion: @escaping (Bool) -> Void) { completion(false) }
    func page(_ page: WebKitPage, didRejectCertificateAt url: URL, error: String) {}
    func pageWebContentProcessDidTerminate(_ page: WebKitPage) {}
    func pageWillChooseFiles(_ page: WebKitPage) {}
    func pageDidChooseFiles(_ page: WebKitPage) {}
}
