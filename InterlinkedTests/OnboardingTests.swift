import XCTest

final class OnboardingTests: XCTestCase {
    func testStepsOnlyCountInOrder() {
        var progress = OnboardingProgress()
        XCTAssertEqual(progress.scene.id, 1)
        XCTAssertFalse(progress.record(.cameBack), "coming back before opening a tab is not progress")
        XCTAssertFalse(progress.record(.split))
        XCTAssertTrue(progress.record(.openedTab))
        XCTAssertFalse(progress.record(.openedTab), "a step counts once")
        XCTAssertEqual(progress.scene.id, 1)
        XCTAssertTrue(progress.record(.cameBack))
        XCTAssertEqual(progress.scene.id, 2)
        XCTAssertEqual(progress.next, .split)
    }

    func testTheLastSceneStaysWhenEverythingIsDone() {
        var progress = OnboardingProgress()
        OnboardingStep.allCases.forEach { progress.record($0) }
        XCTAssertNil(progress.next)
        XCTAssertEqual(progress.scene.id, OnboardingScene.all.last?.id)
    }

    func testEachLineAppearsOnlyWhenItIsNext() {
        let scene = OnboardingScene.all[1]
        var progress = OnboardingProgress()
        [.openedTab, .cameBack].forEach { progress.record($0) }
        XCTAssertEqual(scene.revealed(progress).map(\.step), [.split])
        progress.record(.split)
        XCTAssertEqual(scene.current(progress).step, .closedPane)
        XCTAssertEqual(scene.revealed(progress).map(\.step), [.split, .closedPane])
        XCTAssertFalse(OnboardingScene.all[0].parts[1].onPage, "coming back is told by the coach, not the page")
    }

    func testTheFeatureSceneIsJustItsSwitch() {
        let scene = OnboardingScene.all[2]
        XCTAssertEqual(scene.features, [.appleIntelligence, .jev])
        XCTAssertNil(scene.page)
        XCTAssertEqual(scene.steps, [.intelligenceNext])
        var progress = OnboardingProgress()
        [.openedTab, .cameBack, .split, .closedPane].forEach { progress.record($0) }
        XCTAssertEqual(progress.scene.id, 3)
        XCTAssertTrue(progress.record(.intelligenceNext))
        XCTAssertEqual(progress.scene.id, 4)
        XCTAssertEqual(progress.scene.page, .slowMornings)
        XCTAssertTrue(progress.record(.foundWithMeaning))
        XCTAssertEqual(progress.scene.id, 5)
        XCTAssertEqual(progress.scene.features, [.sharingScreen, .usefulInfo])
        XCTAssertEqual(progress.scene.page, .slowMornings)
        XCTAssertTrue(progress.record(.extrasNext))
        XCTAssertEqual(progress.scene.id, 6)
        XCTAssertNil(progress.scene.page, "the last scene closes the page beside it")
        XCTAssertEqual(progress.scene.features, [.adBlocking, .darkPages])
        XCTAssertTrue(progress.record(.finished))
        XCTAssertNil(progress.next)
    }

    func testEveryStepBelongsToExactlyOneSceneInOrder() {
        XCTAssertEqual(OnboardingScene.all.flatMap(\.steps), OnboardingStep.allCases)
    }

    func testProgressAndDismissalSurviveARelaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "onboarding-\(UUID().uuidString)"))
        let store = OnboardingStore(defaults: defaults)
        var progress = OnboardingProgress()
        progress.record(.openedTab)
        store.progress = progress
        store.dismissed = true
        XCTAssertEqual(OnboardingStore(defaults: defaults).progress, progress)
        XCTAssertTrue(OnboardingStore(defaults: defaults).dismissed)
        store.reset()
        XCTAssertEqual(OnboardingStore(defaults: defaults).progress, OnboardingProgress())
        XCTAssertFalse(OnboardingStore(defaults: defaults).dismissed)
    }

    func testProgressSavedWithARemovedStepStillLoads() throws {
        let saved = #"{"done":["openedTab","cameBack","readCritically"]}"#
        let progress = try JSONDecoder().decode(OnboardingProgress.self, from: Data(saved.utf8))
        XCTAssertEqual(progress.done, [.openedTab, .cameBack])
    }
}
