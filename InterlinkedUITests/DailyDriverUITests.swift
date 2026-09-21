import XCTest

final class DailyDriverUITests: XCTestCase {
    private var server: Process?
    private let port = 8765
    private let base = "http://127.0.0.1:8765"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try startFixtureServer()
    }

    override func tearDownWithError() throws {
        server?.terminate()
        server?.waitUntilExit()
        server = nil
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
        XCTAssertTrue(app.staticTexts["Not Secure"].waitForExistence(timeout: 5) || origin.label.contains("Not Secure"))
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
        return app
    }

    private func startFixtureServer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test-fixtures/server.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if canConnect() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("Fixture server did not start on port \(port)")
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
