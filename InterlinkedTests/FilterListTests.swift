import XCTest
@testable import Interlinked

final class FilterListTests: XCTestCase {
    func testReadsHostRulesAndSkipsEverythingNarrower() {
        let rules = FilterRules.parse("""
        [Adblock Plus 2.0]
        ! comment
        ||ads.example.com^
        ||tracker.net^$third-party
        ||both.org^
        ||both.org^$third-party
        ||scripts.example^$script,third-party
        ||cdn.example.com/ads/banner.js
        ||scoped.example^$domain=news.example
        /banner/*/img^
        example.com##.ad-slot
        @@||allowed.example^
        @@||partial.example^$third-party
        ||UPPER.Example^
        ||nodot^
        ||bad host.example^
        """)

        XCTAssertEqual(rules.blocked, ["ads.example.com", "both.org", "upper.example"])
        XCTAssertEqual(rules.blockedThirdParty, ["tracker.net"])
        XCTAssertEqual(rules.allowed, ["allowed.example"])
        XCTAssertEqual(rules.count, 4)
    }

    func testMergeCombinesLists() {
        var rules = FilterRules.parse("||a.example^")
        rules.merge(FilterRules.parse("||b.example^$3p\n@@||c.example^"))
        XCTAssertEqual(rules.blocked, ["a.example"])
        XCTAssertEqual(rules.blockedThirdParty, ["b.example"])
        XCTAssertEqual(rules.allowed, ["c.example"])
    }

    func testSiteKeyIgnoresLeadingWWW() {
        XCTAssertEqual(SiteKey.site(URL(string: "https://WWW.Example.com/path")), "example.com")
        XCTAssertEqual(SiteKey.site(URL(string: "https://news.example.com/")), "news.example.com")
        XCTAssertNil(SiteKey.site(URL(string: "about:blank")))
    }
}
