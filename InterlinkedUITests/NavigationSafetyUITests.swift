import XCTest

final class NavigationSafetyUITests: XCTestCase {
    private var fixtureServer: Process?
    private var sessionURL: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [repository.appendingPathComponent("test-fixtures/server.py").path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        fixtureServer = server
        Thread.sleep(forTimeInterval: 0.25)

        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterlinkedUITests-\(UUID().uuidString).json")
        let json = #"{"version":1,"tabs":[{"id":{"rawValue":1},"root":{"leaf":1},"active":{"rawValue":1}}],"active":0,"next_tab":2,"next_pane":2,"next_split":1,"surfaces":[[{"rawValue":1},{"kind":"browser","line":"http://127.0.0.1:8765"}]]}"#
        try Data(json.utf8).write(to: session)
        sessionURL = session
    }

    override func tearDownWithError() throws {
        if fixtureServer?.isRunning == true {
            fixtureServer?.terminate()
            fixtureServer?.waitUntilExit()
        }
        if let sessionURL { try? FileManager.default.removeItem(at: sessionURL) }
    }

    func testFlaggedNavigationWaitsForContinue() throws {
        let app = XCUIApplication()
        app.launchEnvironment["INTERLINKED_SESSION"] = try XCTUnwrap(sessionURL).path
        app.launch()

        let link = app.links["Continue at paypal.com"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()

        let warning = app.sheets.firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.staticTexts["Check where this link is going"].exists)
        XCTAssertFalse(app.staticTexts["Navigation completed"].exists)

        warning.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Navigation completed"].waitForExistence(timeout: 10))
    }
}
