import XCTest

final class IntelligencePromptTests: XCTestCase {
    func testEveryFeatureHasAVisibleDefaultAndCorrectProvider() {
        XCTAssertEqual(IntelligencePromptFeature.features(for: .appleIntelligence).count, 3)
        XCTAssertEqual(IntelligencePromptFeature.features(for: .jev).count, 2)
        for feature in IntelligencePromptFeature.allCases {
            XCTAssertFalse(feature.title.isEmpty)
            XCTAssertFalse(feature.defaultText.isEmpty)
        }
    }

    func testPromptsAreLockedToTheShippedText() throws {
        let name = "IntelligencePromptTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let feature = IntelligencePromptFeature.applePageLabel

        IntelligencePromptPreferences.set("Use my page label rules.", for: feature, defaults: defaults)
        XCTAssertEqual(
            IntelligencePromptPreferences.text(for: feature, defaults: defaults),
            feature.defaultText
        )
        XCTAssertFalse(IntelligencePromptPreferences.isCustomized(feature, defaults: defaults))
        XCTAssertTrue(feature.defaultText.contains("one-or-two-sentence description"))
    }

    func testRuntimeVariablesRenderInsideTheShippedPrompt() {
        let rendered = IntelligencePromptPreferences.rendered(.jevMeaningScore, values: ["passage_id": "p-4"])
        XCTAssertTrue(rendered.contains("page element ID p-4"))
        XCTAssertFalse(rendered.contains("{passage_id}"))
    }
}
