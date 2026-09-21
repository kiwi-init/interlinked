import XCTest

final class PageBuiltInsTests: XCTestCase {
    func testSiteKeyIgnoresLeadingWWW() {
        XCTAssertEqual(SiteKey.site(URL(string: "https://WWW.Example.com/path")), "example.com")
        XCTAssertEqual(SiteKey.site(URL(string: "https://news.example.com/")), "news.example.com")
        XCTAssertNil(SiteKey.site(URL(string: "about:blank")))
    }

    func testStandardListsUseHTTPSAndTrustOnlyUBlockLists() {
        XCTAssertTrue(BlockList.standard.allSatisfy { $0.url.scheme == "https" })
        XCTAssertEqual(BlockList.standard.filter(\.trusted).map(\.url.host), Array(repeating: "ublockorigin.github.io", count: 5))
    }
}
