import WebKit
import XCTest

/// Runs Interlinked/Resources/blocker-cosmetics.js on the procedural fixture
/// page with the rules the engine produces for test-fixtures/blocker-filters.txt
/// (blocker/tests/fixtures.rs keeps test-fixtures/blocker-procedural.json in
/// step with the engine). The page checks itself and reports in its title.
@MainActor
final class BlockerCosmeticsTests: XCTestCase {
    func testProceduralRulesHideOnlyMatchingElements() async throws {
        let procedural = try JSONSerialization.jsonObject(with: fixture("test-fixtures/blocker-procedural.json"))
        let title = try await loadFixture(procedural: procedural)
        XCTAssertEqual(title, "Procedural filters: pass")
    }

    func testFixtureFailsWithoutProceduralRules() async throws {
        let title = try await loadFixture(procedural: [String]())
        XCTAssertTrue(title.hasPrefix("Procedural filters: fail: has-text,"), title)
        XCTAssertFalse(title.contains("exception"), title)
    }

    private func loadFixture(procedural: Any) async throws -> String {
        let configuration = try JSONSerialization.data(withJSONObject: [
            "hide": [String](),
            "procedural": procedural,
            "generic": false,
            "binding": "__interlinkedCosmetics",
        ])
        let script = try XCTUnwrap(String(data: fixture("Interlinked/Resources/blocker-cosmetics.js"), encoding: .utf8))
        let source = "(()=>{const cfg=\(String(decoding: configuration, as: UTF8.self));\(script)})();"
        let web = WKWebView()
        // The app runs the script in an isolated world; so does this test.
        web.configuration.userContentController.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .world(name: "interlinked-cosmetics")))
        let page = try XCTUnwrap(String(data: fixture("test-fixtures/blocker-procedural.html"), encoding: .utf8))
        web.loadHTMLString(page, baseURL: URL(string: "http://127.0.0.1:8765/blocker/procedural"))

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let title = try? await web.evaluateJavaScript("document.title") as? String
            if let title, title.hasPrefix("Procedural filters: "), title != "Procedural filters: checking" {
                return title
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The fixture page never reported")
        return ""
    }

    private func fixture(_ path: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent(path))
    }
}
