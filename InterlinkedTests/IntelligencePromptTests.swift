import XCTest

final class IntelligencePromptTests: XCTestCase {
    func testEveryFeatureHasAVisibleDefaultAndCorrectProvider() {
        XCTAssertEqual(IntelligencePromptFeature.features(for: .appleIntelligence).count, 2)
        XCTAssertEqual(IntelligencePromptFeature.features(for: .jev).count, 6)
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

    func testCriticalReadingDefinitionsAreLockedAndDictionaryBased() {
        XCTAssertEqual(
            IntelligencePromptPreferences.rendered(
                .jevCriticalReading,
                values: ["passage_id": "p1"]
            ),
            PassageDecisions.classificationInstruction + " Passage ID: p1."
        )
        XCTAssertTrue(PassageDecisions.Signal.loaded.explanation.hasPrefix("Loaded language:"))
        XCTAssertTrue(PassageDecisions.Signal.pressure.explanation.hasPrefix("Pressure:"))
        XCTAssertTrue(PassageDecisions.Signal.opinion.explanation.hasPrefix("Opinion:"))
        XCTAssertTrue(PassageDecisions.classificationInstruction.contains("dictionary definitions"))
    }

    func testRuntimeVariablesRenderInsideTheShippedPrompt() {
        XCTAssertEqual(
            IntelligencePromptPreferences.rendered(
                .jevPersonalFilter,
                values: ["candidate_id": "candidate-4", "candidate_role": "button"]
            ).contains("candidate-4"),
            true
        )
        XCTAssertTrue(
            IntelligencePromptPreferences.rendered(
                .jevPersonalFilter,
                values: ["candidate_id": "candidate-4", "candidate_role": "button"]
            ).contains("button")
        )
    }
}
