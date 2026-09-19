import XCTest

final class PaneTests: XCTestCase {
    func leaf(_ id: UInt64) -> Pane { .leaf(PaneID(id)) }

    func split(_ id: UInt64, _ axis: SplitAxis, _ first: Pane, _ second: Pane) -> Pane {
        .split(id: SplitID(id), axis: axis, first: first, second: second)
    }

    func testSplittingKeepsThePaneAndHangsTheNewOneBesideIt() {
        var root = leaf(1)
        XCTAssertTrue(root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1)))
        XCTAssertEqual(root, split(1, .columns, leaf(1), leaf(2)))
    }

    func testSplittingAnUnknownPaneDoesNothing() {
        var root = leaf(1)
        XCTAssertFalse(root.split(PaneID(9), axis: .rows, new: PaneID(2), id: SplitID(1)))
        XCTAssertEqual(root, leaf(1))
    }

    func testASplitLandsInsideThePaneItTargets() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        XCTAssertTrue(root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2)))
        XCTAssertEqual(root, split(1, .columns, leaf(1), split(2, .rows, leaf(2), leaf(3))))
    }

    func testClosingANestedPaneCollapsesOnlyItsOwnSplit() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        _ = root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2))
        XCTAssertEqual(root.close(PaneID(3)), PaneID(2))
        XCTAssertEqual(root, split(1, .columns, leaf(1), leaf(2)))
    }

    func testClosingTheFirstChildPromotesTheSecond() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        _ = root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2))
        XCTAssertEqual(root.close(PaneID(1)), PaneID(2))
        XCTAssertEqual(root, split(2, .rows, leaf(2), leaf(3)))
    }

    func testTheLastPaneCannotBeClosed() {
        var root = leaf(1)
        XCTAssertNil(root.close(PaneID(1)))
        XCTAssertEqual(root, leaf(1))
    }

    func testAPanesNeighbourIsTheNearestOneThatWay() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        _ = root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2))

        XCTAssertEqual(root.neighbour(PaneID(1), .right), PaneID(2))
        XCTAssertEqual(root.neighbour(PaneID(2), .left), PaneID(1))
        XCTAssertEqual(root.neighbour(PaneID(3), .left), PaneID(1), "the tall pane is to the left of both of them")
        XCTAssertEqual(root.neighbour(PaneID(2), .down), PaneID(3))
        XCTAssertEqual(root.neighbour(PaneID(3), .up), PaneID(2))
        XCTAssertNil(root.neighbour(PaneID(1), .left))
        XCTAssertNil(root.neighbour(PaneID(1), .up))
        XCTAssertNil(root.neighbour(PaneID(9), .left))
    }

    func testSwappingTwoPanesLeavesTheShapeAlone() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        _ = root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2))
        XCTAssertTrue(root.swap(PaneID(1), PaneID(3)))
        XCTAssertEqual(root, split(1, .columns, leaf(3), split(2, .rows, leaf(2), leaf(1))))
    }

    func testATabIsAGridOfOneSplitEachWay() {
        var root = leaf(1)
        XCTAssertTrue(root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1)))
        XCTAssertTrue(root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2)))
        XCTAssertTrue(root.split(PaneID(1), axis: .rows, new: PaneID(4), id: SplitID(3)))
        XCTAssertEqual(root.leaves().count, 4)
        XCTAssertFalse(root.split(PaneID(1), axis: .columns, new: PaneID(5), id: SplitID(4)))
        XCTAssertFalse(root.split(PaneID(1), axis: .rows, new: PaneID(5), id: SplitID(5)))
        XCTAssertFalse(root.split(PaneID(3), axis: .rows, new: PaneID(5), id: SplitID(6)))
        XCTAssertEqual(root.leaves().count, 4)
    }

    func testAPanesCoordinateIsWhereItIs() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        _ = root.split(PaneID(1), axis: .rows, new: PaneID(3), id: SplitID(2))
        XCTAssertEqual(root.coordinate(PaneID(1)).0, 0)
        XCTAssertEqual(root.coordinate(PaneID(1)).1, 0)
        XCTAssertEqual(root.coordinate(PaneID(3)).0, 1)
        XCTAssertEqual(root.coordinate(PaneID(2)).1, 1)
    }
}

final class IntentTests: XCTestCase {
    func testBrowserCommands() {
        XCTAssertEqual(Intent.command("new tab"), "new-tab")
        XCTAssertEqual(Intent.command("open a new page"), "new-tab")
        XCTAssertEqual(Intent.command("next tab"), "next-tab")
        XCTAssertEqual(Intent.command("go back a tab"), "prev-tab")
        XCTAssertEqual(Intent.command("go to tab three"), "focus-tab 2")
        XCTAssertEqual(Intent.command("close this page"), "close-tab")
    }

    func testRemovedWorkspaceCommandsAreNotExecutable() {
        for said in ["open terminal", "new terminal tab", "show shell", "split this pane down",
                     "divide", "swap pane one with pane two", "make this a file browser", "open agent"] {
            XCTAssertNil(Intent.command(said), said)
        }
        XCTAssertNil(Intent.command("what is the weather like"))
        XCTAssertNil(Intent.command("tab zero"))
    }
}

final class SurfaceTests: XCTestCase {
    func testTabRowsAreBalancedAndNeverExceedFive() {
        XCTAssertEqual(OpenWork.rows(count: 6).map(\.count), [3, 3])
        XCTAssertEqual(OpenWork.rows(count: 11).map(\.count), [4, 4, 3])
        XCTAssertEqual(OpenWork.rows(count: 5).map(\.count), [5])
        XCTAssertTrue(OpenWork.rows(count: 0).isEmpty)
        for count in 1...100 {
            let rows = OpenWork.rows(count: count)
            let sizes = rows.map(\.count)
            XCTAssertEqual(rows.flatMap { Array($0) }, Array(0..<count))
            XCTAssertLessThanOrEqual(sizes.max()!, 5)
            XCTAssertLessThanOrEqual(sizes.max()! - sizes.min()!, 1)
        }
    }

    func testCleanAddressesPreserveNavigationAndMeaningfulParameters() {
        XCTAssertEqual(CompactLine.editable("https://www.spacex.com/"), "spacex.com")
        let original = "https://www.example.com/a%2Fb?q=C%2B%2B&utm_source=test&fbclid=123#part"
        let clean = "example.com/a%2Fb?q=C%2B%2B#part"
        XCTAssertEqual(CompactLine.editable(original), clean)
        XCTAssertEqual(CompactLine.committed(clean, original: original), original)
        XCTAssertEqual(CompactLine.committed(" other.com ", original: original), "other.com")
        XCTAssertEqual(CompactLine.editable("http://localhost:3000/path"), "http://localhost:3000/path")
        XCTAssertEqual(CompactLine.editable("file:///tmp/page.html"), "file:///tmp/page.html")
        XCTAssertEqual(CompactLine.editable("https://person:password@example.com/"), "example.com")
    }

    func testSearchURLDisplaysTheOriginalWordsAndLiteralPlusSigns() {
        XCTAssertEqual(CompactLine.editable("https://www.google.com/search?q=kiwi+browser&source=abc"), "kiwi browser")
        XCTAssertEqual(CompactLine.editable(address(from: "C++ & café").absoluteString), "C++ & café")
        XCTAssertEqual(Kind.browser.compactLabel(for: address(from: "kiwi browser").absoluteString), "kiwi browser")
        XCTAssertNil(CompactLine.searchQuery("https://google.com.evil.test/search?q=fake"))
        XCTAssertNil(CompactLine.searchQuery("https://example.com/search?q=real"))
    }

    func testSearchFeedKeepsThreeUniqueWebResultsInEngineOrder() {
        let data = """
        <rss><channel><title>Engine</title><link>https://bing.com</link>
        <item><title>Unsafe</title><link>javascript:alert(1)</link></item>
        <item><title>One &amp; two</title><link>https://one.test/</link></item>
        <item><title>Duplicate</title><link>https://one.test/</link></item>
        <item><title>Second</title><link>https://two.test/</link></item>
        <item><title>Third</title><link>https://three.test/</link></item>
        <item><title>Fourth</title><link>https://four.test/</link></item>
        </channel></rss>
        """.data(using: .utf8)!
        XCTAssertEqual(SearchResult.parse(data).map(\.title), ["One & two", "Second", "Third"])
        XCTAssertTrue(SearchResult.parse(Data("<broken>".utf8)).isEmpty)
    }

    func testBrowserSearchesWordsAndPreservesSearchPunctuation() {
        for query in ["kiwi browser", "weather", "C++ & café #1", "site:paper.design", "what is https://example.com"] {
            let url = address(from: "  " + query + "  ")
            XCTAssertEqual(url.host, "www.google.com")
            XCTAssertEqual(url.path, "/search")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, query)
        }
        XCTAssertTrue(address(from: "C++ tutorial").absoluteString.contains("C%2B%2B"))
    }

    func testBrowserKeepsURLsAndLocalDevelopmentAddresses() {
        XCTAssertEqual(address(from: "paper.design/docs").absoluteString, "https://paper.design/docs")
        XCTAssertEqual(address(from: "https://example.com/a?q=one#two").absoluteString, "https://example.com/a?q=one#two")
        XCTAssertEqual(address(from: "localhost:3000/app").absoluteString, "http://localhost:3000/app")
        XCTAssertEqual(address(from: "127.0.0.1:8080").absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(address(from: "[::1]:8080").absoluteString, "http://[::1]:8080")
        XCTAssertEqual(address(from: "file:///tmp/page.html").scheme, "file")
        XCTAssertEqual(address(from: " \n ").absoluteString, "about:blank")
    }

    func testOpenWorkDistinguishesDocumentsFromTheSameSite() {
        let title = OpenWork.title(customName: nil, pageTitle: "Kiwi explorations", fallback: "paper.design")
        XCTAssertEqual(title, "Kiwi explorations")
        XCTAssertTrue(OpenWork.matches("kiwi paper", title: title, details: ["https://paper.design/123"]))
        XCTAssertFalse(OpenWork.matches("invoice paper", title: title, details: ["https://paper.design/123"]))
    }

    func testOpenWorkKeepsCustomNamesAndHandlesMissingMetadata() {
        XCTAssertEqual(OpenWork.title(customName: " My work ", pageTitle: "Homepage", fallback: "site.test"), "My work")
        XCTAssertEqual(OpenWork.title(customName: nil, pageTitle: " \n ", fallback: "site.test"), "site.test")
        XCTAssertTrue(OpenWork.matches(" \n ", title: "Page", details: []))
        XCTAssertTrue(OpenWork.matches("CAFÉ", title: "Cafe notes", details: []))
    }

    func testAKindIsKnownByMoreThanOneName() {
        XCTAssertEqual(Kind.parse("browser"), .browser)
        XCTAssertEqual(Kind.parse("shell"), .terminal)
        XCTAssertEqual(Kind.parse("file"), .files)
        XCTAssertNil(Kind.parse("kiwi"))
        for kind in Kind.allCases {
            XCTAssertEqual(Kind.parse(kind.name), kind)
        }
    }

    func testSurfacesBelongToPanes() {
        var surfaces = Surfaces()
        XCTAssertEqual(surfaces.kind(PaneID(1)), .blank)
        XCTAssertEqual(surfaces.line(PaneID(1)), "")
        surfaces.setKind(PaneID(1), .browser)
        surfaces.setLine(PaneID(1), "github.com")
        surfaces.setLine(PaneID(2), "~/www")
        XCTAssertEqual(surfaces.kind(PaneID(1)), .browser)
        XCTAssertEqual(surfaces.line(PaneID(1)), "github.com")
        surfaces.setKind(PaneID(1), .terminal)
        XCTAssertEqual(surfaces.line(PaneID(1)), "")
        XCTAssertEqual(surfaces.line(PaneID(2)), "~/www")
        surfaces.forget { $0 == PaneID(1) }
        XCTAssertEqual(surfaces.line(PaneID(2)), "")
    }

    func testATabIsNamedByItsWork() {
        var surfaces = Surfaces()
        var tab = Tab(id: TabID(1), pane: PaneID(1))
        XCTAssertEqual(surfaces.tabTitle(tab), "empty")
        surfaces.setKind(PaneID(1), .terminal)
        XCTAssertEqual(surfaces.tabTitle(tab), "terminal")
        surfaces.setLine(PaneID(1), "~/www")
        XCTAssertEqual(surfaces.tabTitle(tab), "~/www")
        surfaces.setKind(PaneID(1), .browser)
        surfaces.setLine(PaneID(1), "https://paper.design/")
        XCTAssertEqual(surfaces.tabTitle(tab), "paper.design")
        tab.name = "work"
        XCTAssertEqual(surfaces.tabTitle(tab), "work")
    }
}

final class ThemeTests: XCTestCase {
    func testASidebarSettlesOntoARealWidthOrCollapses() {
        XCTAssertEqual(Metrics.settleSidebar(80), 0)
        XCTAssertEqual(Metrics.settleSidebar(Metrics.sidebarCollapse - 1), 0)
        XCTAssertEqual(Metrics.settleSidebar(140), Metrics.sidebarMin)
        XCTAssertEqual(Metrics.settleSidebar(216), 216)
        XCTAssertEqual(Metrics.settleSidebar(800), Metrics.sidebarMax)
    }
}

final class BrowserMigrationTests: XCTestCase {
    func testSplitPagesBecomeTabsAndKeepTheirURLsAndSelection() {
        var split = Tab(id: TabID(5), pane: PaneID(10))
        _ = split.split(PaneID(10), axis: .columns, new: PaneID(11), id: SplitID(1))
        split.name = "Reference"
        var old = Session(version: 1, tabs: [split, Tab(id: TabID(6), pane: PaneID(12))], active: 0,
            next_tab: 7, next_pane: 14, next_split: 2,
            surfaces: [SurfacePair(pane: PaneID(10), surface: Surface(kind: .browser, line: "https://one.test/a")),
                       SurfacePair(pane: PaneID(11), surface: Surface(kind: .browser, line: "https://two.test/b")),
                       SurfacePair(pane: PaneID(12), surface: Surface(kind: .terminal, line: "/tmp")),
                       SurfacePair(pane: PaneID(13), surface: Surface(kind: .terminal, line: "/Users/jow"))],
            tint: .ink, sidebar: 0, sidebar_last: 216)
        old = old.browserOnly()
        XCTAssertEqual(old.tabs.count, 2)
        XCTAssertEqual(old.tabs[old.active].active, PaneID(11))
        XCTAssertEqual(old.tabs[old.active].id, TabID(5))
        XCTAssertEqual(old.tabs[old.active].name, "Reference")
        XCTAssertEqual(Set(old.tabs.map(\.id)).count, 2)
        XCTAssertTrue(old.tabs.allSatisfy { $0.root == .leaf($0.active) })
        XCTAssertEqual(old.surfaces.map { $0.surface.line }, ["https://one.test/a", "https://two.test/b"])
        XCTAssertTrue(old.surfaces.allSatisfy { $0.surface.kind == .browser })
        let again = old.browserOnly()
        XCTAssertEqual(again.tabs, old.tabs)
        XCTAssertEqual(again.active, old.active)
        XCTAssertEqual(again.next_tab, old.next_tab)
    }

    func testLegacyTerminalFieldsDecodeWithoutRestoringAShell() throws {
        let json = #"{"version":1,"tabs":[],"active":0,"next_tab":1,"next_pane":2,"next_split":1,"surfaces":[],"terminal_open":true,"terminal_height":220,"terminal_pane":1}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8)).browserOnly()
        XCTAssertTrue(session.isKnown)
        XCTAssertTrue(session.tabs.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        XCTAssertFalse(encoded.contains("terminal"))
    }
}

final class DomainIconCacheTests: XCTestCase {
    func testSameDomainSharesOneRequestAndCachedImage() throws {
        var cache = DomainIconCache<String>()
        _ = cache.retain([PaneID(1): "example.com", PaneID(2): "example.com"])
        let token = try XCTUnwrap(cache.begin("example.com"))
        XCTAssertNil(cache.begin("example.com"))
        XCTAssertTrue(cache.complete("example.com", token: token, value: "icon"))
        XCTAssertEqual(cache.value(for: PaneID(1)), "icon")
        XCTAssertEqual(cache.value(for: PaneID(2)), "icon")
        _ = cache.retain([PaneID(1): "example.com", PaneID(2): "example.com", PaneID(3): "example.com"])
        XCTAssertEqual(cache.value(for: PaneID(3)), "icon")
        XCTAssertNil(cache.begin("example.com"))
    }

    func testRetainedByOtherTabsAndReleasedAfterLastTabLeaves() throws {
        var cache = DomainIconCache<String>()
        _ = cache.retain([PaneID(1): "example.com", PaneID(2): "example.com"])
        let token = try XCTUnwrap(cache.begin("example.com"))
        cache.complete("example.com", token: token, value: "icon")
        XCTAssertTrue(cache.retain([PaneID(2): "example.com"]).isEmpty)
        XCTAssertEqual(cache.value(for: PaneID(2)), "icon")
        XCTAssertEqual(cache.retain([PaneID(2): "other.com"]), ["example.com"])
        XCTAssertNil(cache.value(for: PaneID(2)))
        _ = cache.retain([PaneID(3): "example.com"])
        let next = try XCTUnwrap(cache.begin("example.com"))
        XCTAssertNotEqual(next, token)
        XCTAssertFalse(cache.complete("example.com", token: token, value: "stale"))
        XCTAssertTrue(cache.complete("example.com", token: next, value: "fresh"))
        XCTAssertEqual(cache.value(for: PaneID(3)), "fresh")
    }

    func testFailedLookupDoesNotRefetchUntilDomainIsClosed() throws {
        var cache = DomainIconCache<String>()
        _ = cache.retain([PaneID(1): "example.com"])
        let token = try XCTUnwrap(cache.begin("example.com"))
        cache.complete("example.com", token: token, value: nil)
        XCTAssertNil(cache.begin("example.com"))
        _ = cache.retain([:])
        _ = cache.retain([PaneID(1): "example.com"])
        XCTAssertNotNil(cache.begin("example.com"))
    }

    func testDomainIgnoresPathAndQueryButKeepsDistinctHosts() {
        XCTAssertEqual(DomainIconCache<String>.domain(URL(string: "https://EXAMPLE.com/a?b=1")), "example.com")
        XCTAssertEqual(DomainIconCache<String>.domain(URL(string: "http://example.com/b")), "example.com")
        XCTAssertEqual(DomainIconCache<String>.domain(URL(string: "https://studio.example.com/")), "studio.example.com")
        XCTAssertNil(DomainIconCache<String>.domain(URL(string: "file:///tmp/page.html")))
    }
}
