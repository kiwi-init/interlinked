import XCTest

final class IntelligencePromptTests: XCTestCase {
    private func isolatedDefaults() throws -> (name: String, defaults: UserDefaults) {
        let name = "IntelligencePromptTests-" + UUID().uuidString
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    func testEveryFeatureHasAVisibleDefaultAndCorrectProvider() {
        XCTAssertEqual(IntelligencePromptFeature.features(for: .appleIntelligence).count, 4)
        XCTAssertEqual(IntelligencePromptFeature.features(for: .jev).count, 6)
        for feature in IntelligencePromptFeature.allCases {
            XCTAssertFalse(feature.title.isEmpty)
            XCTAssertFalse(feature.defaultText.isEmpty)
        }
    }

    func testCustomPromptPersistsAndCanBeRestored() throws {
        let storage = try isolatedDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.name) }
        let feature = IntelligencePromptFeature.applePageLabel

        XCTAssertEqual(
            IntelligencePromptPreferences.text(for: feature, defaults: storage.defaults),
            feature.defaultText
        )
        XCTAssertFalse(IntelligencePromptPreferences.isCustomized(feature, defaults: storage.defaults))

        IntelligencePromptPreferences.set("Use my page label rules.", for: feature, defaults: storage.defaults)
        XCTAssertEqual(
            IntelligencePromptPreferences.text(for: feature, defaults: storage.defaults),
            "Use my page label rules."
        )
        XCTAssertTrue(IntelligencePromptPreferences.isCustomized(feature, defaults: storage.defaults))

        IntelligencePromptPreferences.reset(feature, defaults: storage.defaults)
        XCTAssertEqual(
            IntelligencePromptPreferences.text(for: feature, defaults: storage.defaults),
            feature.defaultText
        )
        XCTAssertFalse(IntelligencePromptPreferences.isCustomized(feature, defaults: storage.defaults))
    }

    func testRuntimeVariablesRenderInsideCustomPrompt() throws {
        let storage = try isolatedDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.name) }
        let feature = IntelligencePromptFeature.jevPersonalFilter

        IntelligencePromptPreferences.set(
            "Evaluate {candidate_id} with role {candidate_role}.",
            for: feature,
            defaults: storage.defaults
        )
        XCTAssertEqual(
            IntelligencePromptPreferences.rendered(
                feature,
                values: ["candidate_id": "candidate-4", "candidate_role": "button"],
                defaults: storage.defaults
            ),
            "Evaluate candidate-4 with role button."
        )
    }

    func testBlankPromptRestoresTheDefault() throws {
        let storage = try isolatedDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.name) }
        let feature = IntelligencePromptFeature.jevVaultSearch

        IntelligencePromptPreferences.set("Custom", for: feature, defaults: storage.defaults)
        IntelligencePromptPreferences.set("  \n ", for: feature, defaults: storage.defaults)

        XCTAssertEqual(
            IntelligencePromptPreferences.text(for: feature, defaults: storage.defaults),
            feature.defaultText
        )
        XCTAssertFalse(IntelligencePromptPreferences.isCustomized(feature, defaults: storage.defaults))
    }
}
