import XCTest

final class DailyDriverUITests: XCTestCase {
    private let port = 8765
    private let base = "http://127.0.0.1:8765"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try requireFixtureServer()
    }

    func testMisleadingTitleCannotReplaceHTTPOrigin() throws {
        let app = launch(opening: "\(base)/identity/lookalike")
        let origin = app.buttons["page-origin"]
        XCTAssertTrue(origin.waitForExistence(timeout: 20))
        XCTAssertTrue(origin.label.contains("127.0.0.1") || origin.label.contains("Not Secure"))
        XCTAssertFalse(origin.label.localizedCaseInsensitiveContains("gmail"))
        let address = app.buttons["page-address"]
        XCTAssertTrue(address.exists)
        origin.click()
        let inspector = app.groups["identity-inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5) || app.staticTexts["Connection"].waitForExistence(timeout: 5))
        let notSecure = inspector.staticTexts.matching(NSPredicate(format: "value BEGINSWITH[c] 'not secure'")).firstMatch
        XCTAssertTrue(notSecure.waitForExistence(timeout: 5))
        let site = app.staticTexts.matching(NSPredicate(format: "value CONTAINS '127.0.0.1'")).firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5))
    }

    func testIdentityInspectorShowsFullURLAndCloses() throws {
        let app = launch(opening: "\(base)/identity/lookalike")
        let origin = app.buttons["page-origin"]
        XCTAssertTrue(origin.waitForExistence(timeout: 20))
        origin.click()
        XCTAssertTrue(app.buttons["close-identity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["identity-edit-address"].exists)
        app.buttons["close-identity"].click()
        XCTAssertTrue(app.buttons["page-origin"].waitForExistence(timeout: 5))
    }

    func testCapabilityIndexLoadsReleaseBlockerFixtures() throws {
        let app = launch(opening: base)
        let address = app.buttons["page-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20))
        let origin = app.buttons["page-origin"]
        XCTAssertTrue(origin.waitForExistence(timeout: 20))
        XCTAssertTrue(origin.label.contains("127.0.0.1") || origin.label.contains("Not Secure"))
    }

    private func launch(opening url: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-interlinked-ui-testing", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["INTERLINKED_UI_TEST_URL"] = url
        app.launch()
        // The pointer stays where the last test left it. Over the page handle it
        // expands the handle, so start each test with the pointer on the page.
        let window = app.windows.firstMatch
        if window.waitForExistence(timeout: 10) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).hover()
        }
        return app
    }

    /// The runner is sandboxed and cannot start test-fixtures/server.py, so
    /// the Interlinked scheme starts it before testing (script/fixture-server).
    private func requireFixtureServer() throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if canConnect() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NSError(domain: "DailyDriverUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Fixture server is not running on port \(port). "
                + "Test with the Interlinked scheme, or run script/fixture-server start.",
        ])
    }

    private func canConnect() -> Bool {
        var request = URLRequest(url: URL(string: base)!)
        request.timeoutInterval = 0.3
        var ok = false
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 0.5)
        return ok
    }
}
