import XCTest

final class TrustedOriginTests: XCTestCase {
    func testHTTPSShowsRegistrableDomainNotPageTitle() {
        let origin = TrustedOrigin.inspect("https://mail.example.com/inbox?q=secret")
        XCTAssertEqual(origin?.transport, .https)
        XCTAssertEqual(origin?.displayHost, "example.com")
        XCTAssertEqual(origin?.compactLabel, "example.com")
        XCTAssertFalse(origin?.compactLabel.contains("Inbox") == true)
        XCTAssertTrue(origin?.accessibilityLabel.contains("HTTPS") == true)
        XCTAssertTrue(origin?.accessibilityLabel.contains("example.com") == true)
        XCTAssertTrue(origin?.fullURL.hasPrefix("https://mail.example.com/inbox") == true)
        XCTAssertFalse(origin?.fullURL.contains("Gmail") == true)
    }

    func testHTTPIsVisiblyInsecure() {
        let origin = TrustedOrigin.inspect("http://login.bank.test/session")
        XCTAssertEqual(origin?.transport, .http)
        XCTAssertEqual(origin?.compactLabel, "Not Secure bank.test")
        XCTAssertTrue(origin?.accessibilityLabel.contains("not secure HTTP") == true)
        XCTAssertTrue(origin?.connectionDetail.contains("not encrypted") == true)
    }

    func testUnicodeHostDisplaysPunycode() {
        let unicode = TrustedOrigin.inspect("https://аррӏе.com/")
        let punycode = TrustedOrigin.inspect("https://xn--80ak6aa92e.com/")
        XCTAssertEqual(unicode?.asciiHost.contains("xn--"), true)
        XCTAssertEqual(unicode?.displayHost.contains("xn--"), true)
        XCTAssertEqual(punycode?.displayHost.contains("xn--"), true)
        XCTAssertNotEqual(unicode?.displayHost, "apple.com")
        XCTAssertNotEqual(punycode?.displayHost, "apple.com")
    }

    func testMixedScriptHostIsFlagged() {
        let origin = TrustedOrigin.inspect("https://appιe.com/")
        XCTAssertEqual(origin?.mixedScript, true)
        XCTAssertTrue(origin?.connectionDetail.contains("writing systems") == true)
    }

    func testCredentialsNeverAppearInDisplayedURL() {
        let origin = TrustedOrigin.inspect("https://person:secret@example.com/path")
        XCTAssertEqual(origin?.displayHost, "example.com")
        XCTAssertFalse(origin?.fullURL.contains("person") == true)
        XCTAssertFalse(origin?.fullURL.contains("secret") == true)
    }

    func testBlankAndLocalPagesHaveNoRemoteIdentity() {
        XCTAssertNil(TrustedOrigin.inspect("about:blank"))
        XCTAssertNil(TrustedOrigin.inspect(""))
    }

    func testLocalFixturesCoverReleaseBlockerFlows() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test-fixtures")
        for name in [
            "web-capabilities.html", "identity-lookalike.html", "inbox.html",
            "public-article.html", "runtime.html", "sw.js", "COMPATIBILITY.md"
        ] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), name)
        }
    }

    func testLoopbackHTTPKeepsTheFullHost() {
        let origin = TrustedOrigin.inspect("http://127.0.0.1:8765/identity/lookalike")
        XCTAssertEqual(origin?.displayHost, "127.0.0.1")
        XCTAssertEqual(origin?.transport, .http)
        XCTAssertTrue(origin?.compactLabel.contains("Not Secure") == true)
        XCTAssertTrue(origin?.compactLabel.contains("127.0.0.1") == true)
    }
}

@MainActor
final class AIContentGrantTests: XCTestCase {
    func testGrantsAreOriginScopedAndPersistOnlyWhenChosen() throws {
        let name = "OriginGrants-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let first = AIContentGrantStore(defaults: defaults, storageKey: name)
        first.grant("https://news.example", remember: false)
        XCTAssertTrue(first.allows("https://news.example"))
        XCTAssertFalse(first.isRemembered("https://news.example"))

        let sessionOnly = AIContentGrantStore(defaults: defaults, storageKey: name)
        XCTAssertFalse(sessionOnly.allows("https://news.example"))

        first.grant("https://news.example", remember: true)
        let remembered = AIContentGrantStore(defaults: defaults, storageKey: name)
        XCTAssertTrue(remembered.allows("https://news.example"))
        remembered.revoke("https://news.example")
        XCTAssertFalse(AIContentGrantStore(defaults: defaults, storageKey: name).allows("https://news.example"))
    }
}

final class PagePrivacyTests: XCTestCase {
    func testSessionCookiesAndLogoutMarkAuthenticatedPages() {
        XCTAssertTrue(PagePrivacy.isAuthenticated(
            url: "https://hr.example.com/home",
            sensitive: false,
            cookieNames: [],
            hasLogoutControl: true,
            httpOnlyCookieNames: []
        ))
        XCTAssertTrue(PagePrivacy.isAuthenticated(
            url: "https://mail.example.com/inbox",
            sensitive: false,
            cookieNames: [],
            hasLogoutControl: false,
            httpOnlyCookieNames: ["SID"]
        ))
        XCTAssertFalse(PagePrivacy.isAuthenticated(
            url: "https://www.example.com/article",
            sensitive: false,
            cookieNames: ["_ga", "CookieConsent"],
            hasLogoutControl: false,
            httpOnlyCookieNames: []
        ))
        XCTAssertTrue(PagePrivacy.isAuthenticated(
            url: "https://person:secret@example.com/",
            sensitive: false,
            cookieNames: [],
            hasLogoutControl: false,
            httpOnlyCookieNames: []
        ))
    }

    func testFormAndPasswordExclusionsRemainIntact() {
        XCTAssertTrue(PagePrivacy.isAuthenticated(
            url: "https://www.example.com/account",
            sensitive: true,
            cookieNames: [],
            hasLogoutControl: false,
            httpOnlyCookieNames: []
        ))
        XCTAssertTrue(PageTextBridge.install.contains("form,input,textarea,select,[contenteditable]"))
        XCTAssertTrue(PageTextBridge.install.contains("input[type=\"password\"],textarea,[contenteditable=\"true\"]"))
    }
}
