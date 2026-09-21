import XCTest

final class CommandKeyStateTests: XCTestCase {
    func testPhysicalCommandKeysAreReadIndependently() {
        XCTAssertNotEqual(CommandKeyState.leftMask, CommandKeyState.rightMask)
        let genericCommand: UInt = 1 << 20

        let leftOnly = CommandKeyState.read(rawModifierFlags: genericCommand | CommandKeyState.leftMask)
        XCTAssertEqual(leftOnly, CommandKeyState(left: true, right: false))

        let rightOnly = CommandKeyState.read(rawModifierFlags: genericCommand | CommandKeyState.rightMask)
        XCTAssertEqual(rightOnly, CommandKeyState(left: false, right: true))

        let both = CommandKeyState.read(
            rawModifierFlags: genericCommand | CommandKeyState.leftMask | CommandKeyState.rightMask
        )
        XCTAssertEqual(both, CommandKeyState(left: true, right: true))

        XCTAssertEqual(
            CommandKeyState.read(rawModifierFlags: genericCommand),
            CommandKeyState(left: false, right: false),
            "The generic Command flag must not be mistaken for the left key"
        )
    }

    func testRightCommandUsesItsPhysicalKeyCodeWhenChromiumStripsDeviceBits() {
        let pressed = CommandKeyState.updating(
            CommandKeyState(left: false, right: false),
            eventKeyCode: CommandKeyState.rightKeyCode,
            rawModifierFlags: CommandKeyState.commandMask
        )
        XCTAssertEqual(pressed, CommandKeyState(left: false, right: true))

        let released = CommandKeyState.updating(
            pressed,
            eventKeyCode: CommandKeyState.rightKeyCode,
            rawModifierFlags: 0
        )
        XCTAssertEqual(released, CommandKeyState(left: false, right: false))
    }

    func testCommandSidesStayIndependentAcrossPressAndReleaseOrder() {
        var state = CommandKeyState(left: false, right: false)
        state = CommandKeyState.updating(
            state,
            eventKeyCode: CommandKeyState.leftKeyCode,
            rawModifierFlags: CommandKeyState.commandMask
        )
        XCTAssertEqual(state, CommandKeyState(left: true, right: false))

        state = CommandKeyState.updating(
            state,
            eventKeyCode: CommandKeyState.rightKeyCode,
            rawModifierFlags: CommandKeyState.commandMask
        )
        XCTAssertEqual(state, CommandKeyState(left: true, right: true))

        state = CommandKeyState.updating(
            state,
            eventKeyCode: CommandKeyState.leftKeyCode,
            rawModifierFlags: CommandKeyState.commandMask
        )
        XCTAssertEqual(state, CommandKeyState(left: false, right: true))

        state = CommandKeyState.updating(
            state,
            eventKeyCode: CommandKeyState.rightKeyCode,
            rawModifierFlags: 0
        )
        XCTAssertEqual(state, CommandKeyState(left: false, right: false))
    }

    func testDeviceSpecificEventStateWinsOverStaleTrackedState() {
        let stale = CommandKeyState(left: true, right: false)
        let corrected = CommandKeyState.updating(
            stale,
            eventKeyCode: CommandKeyState.rightKeyCode,
            rawModifierFlags: CommandKeyState.commandMask | CommandKeyState.rightMask
        )
        XCTAssertEqual(corrected, CommandKeyState(left: false, right: true))
    }

    func testUnrelatedModifierEventDoesNotChangeACommandSide() {
        let held = CommandKeyState(left: false, right: true)
        let unchanged = CommandKeyState.updating(
            held,
            eventKeyCode: 56,
            rawModifierFlags: CommandKeyState.commandMask
        )
        XCTAssertEqual(unchanged, held)
    }

    func testGenericCommandReleaseClearsAnyStaleSideState() {
        let stale = CommandKeyState(left: true, right: true)
        let cleared = CommandKeyState.updating(
            stale,
            eventKeyCode: CommandKeyState.leftKeyCode,
            rawModifierFlags: 0
        )
        XCTAssertEqual(cleared, CommandKeyState(left: false, right: false))
    }
}

final class CopiedPageURLFeedbackTests: XCTestCase {
    func testCopiedFeedbackRequiresAnActualCopiedURL() {
        XCTAssertFalse(CopiedPageURLFeedback.isShowing(copied: nil, current: nil))
        XCTAssertFalse(CopiedPageURLFeedback.isShowing(copied: nil, current: "https://example.com"))
        XCTAssertFalse(CopiedPageURLFeedback.isShowing(copied: "https://example.com", current: nil))
        XCTAssertFalse(CopiedPageURLFeedback.isShowing(copied: "https://a.example", current: "https://b.example"))
        XCTAssertTrue(CopiedPageURLFeedback.isShowing(copied: "https://example.com/", current: "https://example.com/"))
    }
}

final class NewTabPageTests: XCTestCase {
    func testEmptyLinesAreNewTabs() {
        XCTAssertTrue(NewTabPage.matches(line: ""))
        XCTAssertTrue(NewTabPage.matches(line: "   \n"))
        XCTAssertFalse(NewTabPage.matches(line: "about:blank"))
        XCTAssertFalse(NewTabPage.matches(line: "https://example.com"))
    }

    func testNewTabHandleStaysExpandedWithoutHover() {
        XCTAssertTrue(PageHandleExpansion.showsOpenWork(
            overviewOpen: false, panelOpen: false, hovering: false, editing: false, isNewTab: true, voiceActive: false
        ))
        XCTAssertFalse(PageHandleExpansion.showsOpenWork(
            overviewOpen: true, panelOpen: false, hovering: false, editing: false, isNewTab: true, voiceActive: false
        ))
        XCTAssertFalse(PageHandleExpansion.showsOpenWork(
            overviewOpen: false, panelOpen: false, hovering: false, editing: false, isNewTab: false, voiceActive: false
        ))
        XCTAssertTrue(PageHandleExpansion.showsOpenWork(
            overviewOpen: false, panelOpen: false, hovering: true, editing: false, isNewTab: false, voiceActive: false
        ))
        XCTAssertFalse(PageHandleExpansion.showsOpenWork(
            overviewOpen: false, panelOpen: false, hovering: false, editing: false, isNewTab: true, voiceActive: true
        ))
    }
}

final class PageURLCopyShortcutTests: XCTestCase {
    func testOnlyExactCommandShiftCMatches() {
        XCTAssertTrue(PageURLCopyShortcut.matches(
            character: "C", command: true, shift: true, option: false, control: false, function: false
        ))
        XCTAssertFalse(PageURLCopyShortcut.matches(
            character: "c", command: true, shift: false, option: false, control: false, function: false
        ))
        XCTAssertFalse(PageURLCopyShortcut.matches(
            character: "c", command: false, shift: true, option: false, control: false, function: false
        ))
        XCTAssertFalse(PageURLCopyShortcut.matches(
            character: "c", command: true, shift: true, option: true, control: false, function: false
        ))
        XCTAssertFalse(PageURLCopyShortcut.matches(
            character: "c", command: true, shift: true, option: false, control: true, function: false
        ))
        XCTAssertFalse(PageURLCopyShortcut.matches(
            character: "v", command: true, shift: true, option: false, control: false, function: false
        ))
    }
}

final class ToolboxShortcutTests: XCTestCase {
    func testToolboxUsesConventionalMacShortcuts() {
        XCTAssertEqual(ToolboxShortcut.find.label, "⌘F")
        XCTAssertEqual(ToolboxShortcut.settings.label, "⌘,")
        XCTAssertEqual(ToolboxShortcut.reading.label, "")
    }
}

final class TabClosingPolicyTests: XCTestCase {
    func testOnlyClosingTheLastTabOpensAReplacement() {
        XCTAssertTrue(TabClosingPolicy.opensReplacementTab(remainingTabCount: 0))
        XCTAssertFalse(TabClosingPolicy.opensReplacementTab(remainingTabCount: 1))
        XCTAssertFalse(TabClosingPolicy.opensReplacementTab(remainingTabCount: 8))
    }
}

final class PaneTests: XCTestCase {
    func leaf(_ id: UInt64) -> Pane { .leaf(PaneID(id)) }

    func split(_ id: UInt64, _ axis: SplitAxis, _ first: Pane, _ second: Pane) -> Pane {
        .split(id: SplitID(id), axis: axis, first: first, second: second)
    }

    func testSplittingKeepsThePaneAndHangsTheNewOneBesideIt() {
        var root = leaf(1)
        XCTAssertTrue(root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1)))
        XCTAssertEqual(root, split(1, .columns, leaf(1), leaf(2)))
    }

    func testSplittingAnUnknownPaneDoesNothing() {
        var root = leaf(1)
        XCTAssertFalse(root.split(PaneID(9), axis: .rows, new: PaneID(2), id: SplitID(1)))
        XCTAssertEqual(root, leaf(1))
    }

    func testASplitLandsInsideThePaneItTargets() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        XCTAssertTrue(root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2)))
        XCTAssertEqual(root, split(1, .columns, leaf(1), split(2, .rows, leaf(2), leaf(3))))
    }

    func testClosingANestedPaneCollapsesOnlyItsOwnSplit() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        _ = root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2))
        XCTAssertEqual(root.close(PaneID(3)), PaneID(2))
        XCTAssertEqual(root, split(1, .columns, leaf(1), leaf(2)))
    }

    func testClosingTheFirstChildPromotesTheSecond() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        _ = root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2))
        XCTAssertEqual(root.close(PaneID(1)), PaneID(2))
        XCTAssertEqual(root, split(2, .rows, leaf(2), leaf(3)))
    }

    func testTheLastPaneCannotBeClosed() {
        var root = leaf(1)
        XCTAssertNil(root.close(PaneID(1)))
        XCTAssertEqual(root, leaf(1))
    }

    func testAPanesNeighbourIsTheNearestOneThatWay() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        _ = root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2))

        XCTAssertEqual(root.neighbour(PaneID(1), .right), PaneID(2))
        XCTAssertEqual(root.neighbour(PaneID(2), .left), PaneID(1))
        XCTAssertEqual(root.neighbour(PaneID(3), .left), PaneID(1), "the tall pane is to the left of both of them")
        XCTAssertEqual(root.neighbour(PaneID(2), .down), PaneID(3))
        XCTAssertEqual(root.neighbour(PaneID(3), .up), PaneID(2))
        XCTAssertNil(root.neighbour(PaneID(1), .left))
        XCTAssertNil(root.neighbour(PaneID(1), .up))
        XCTAssertNil(root.neighbour(PaneID(9), .left))
    }

    func testSwappingTwoPanesLeavesTheShapeAlone() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        _ = root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2))
        XCTAssertTrue(root.swap(PaneID(1), PaneID(3)))
        XCTAssertEqual(root, split(1, .columns, leaf(3), split(2, .rows, leaf(2), leaf(1))))
    }

    func testATabIsAGridOfOneSplitEachWay() {
        var root = leaf(1)
        XCTAssertTrue(root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1)))
        XCTAssertTrue(root.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2)))
        XCTAssertTrue(root.split(PaneID(1), axis: .rows, new: PaneID(4), id: SplitID(3)))
        XCTAssertEqual(root.leaves().count, 4)
        XCTAssertFalse(root.split(PaneID(1), axis: .columns, new: PaneID(5), id: SplitID(4)))
        XCTAssertFalse(root.split(PaneID(1), axis: .rows, new: PaneID(5), id: SplitID(5)))
        XCTAssertFalse(root.split(PaneID(3), axis: .rows, new: PaneID(5), id: SplitID(6)))
        XCTAssertEqual(root.leaves().count, 4)
    }

    func testAPanesCoordinateIsWhereItIs() {
        var root = leaf(1)
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        _ = root.split(PaneID(1), axis: .rows, new: PaneID(3), id: SplitID(2))
        XCTAssertEqual(root.coordinate(PaneID(1)).0, 0)
        XCTAssertEqual(root.coordinate(PaneID(1)).1, 0)
        XCTAssertEqual(root.coordinate(PaneID(3)).0, 1)
        XCTAssertEqual(root.coordinate(PaneID(2)).1, 1)
    }
}

final class SplitViewTests: XCTestCase {
    func testATabSplitsIntoTwoPagesAtMost() {
        var tab = Tab(id: TabID(1), pane: PaneID(1))
        XCTAssertFalse(tab.isSplit)
        XCTAssertTrue(tab.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1)))
        XCTAssertEqual(tab.panes, [PaneID(1), PaneID(2)])
        XCTAssertEqual(tab.active, PaneID(2))
        XCTAssertEqual(tab.otherPane, PaneID(1))
        XCTAssertFalse(tab.canSplit)
        XCTAssertFalse(tab.split(PaneID(2), axis: .rows, new: PaneID(3), id: SplitID(2)))
        XCTAssertEqual(tab.panes.count, Tab.maxPanes)
    }

    func testReplacingAPageKeepsItsSide() {
        var root = Pane.leaf(PaneID(1))
        _ = root.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        XCTAssertTrue(root.replace(PaneID(1), with: PaneID(7)))
        XCTAssertEqual(root.leaves(), [PaneID(7), PaneID(2)])
        XCTAssertFalse(root.replace(PaneID(2), with: PaneID(7)), "a page cannot appear twice")
        XCTAssertFalse(root.replace(PaneID(9), with: PaneID(8)))
    }

    func testClosingOnePageOfASplitKeepsTheOther() {
        var tab = Tab(id: TabID(1), pane: PaneID(1))
        _ = tab.split(PaneID(1), axis: .columns, new: PaneID(2), id: SplitID(1))
        XCTAssertTrue(tab.close(PaneID(2)))
        XCTAssertEqual(tab.panes, [PaneID(1)])
        XCTAssertEqual(tab.active, PaneID(1))
        XCTAssertNil(tab.otherPane)
    }
}

final class SiteMenuHomeTests: XCTestCase {
    func testHomeIsTheLogoLinkOrTheOrigin() throws {
        let page = try XCTUnwrap(URL(string: "https://www.example.com/shop/item?id=4"))
        XCTAssertEqual(SiteMenuHome.url("https://www.example.com/en/", current: page)?.absoluteString, "https://www.example.com/en/")
        XCTAssertEqual(SiteMenuHome.url("", current: page)?.absoluteString, "https://www.example.com/")
        XCTAssertEqual(SiteMenuHome.url("javascript:void(0)", current: page)?.absoluteString, "https://www.example.com/")
    }

    func testOnlyTheHomePageItselfCountsAsHome() throws {
        XCTAssertTrue(SiteMenuHome.matches(try XCTUnwrap(URL(string: "https://example.com/")), home: "https://example.com/"))
        XCTAssertTrue(SiteMenuHome.matches(try XCTUnwrap(URL(string: "https://example.com")), home: ""))
        XCTAssertFalse(SiteMenuHome.matches(try XCTUnwrap(URL(string: "https://example.com/docs")), home: "https://example.com/"))
        XCTAssertFalse(SiteMenuHome.matches(try XCTUnwrap(URL(string: "https://example.com/?q=x")), home: "https://example.com/"))
    }
}

final class IntentTests: XCTestCase {
    func testBrowserCommands() {
        XCTAssertEqual(Intent.command("new tab"), "new-tab")
        XCTAssertEqual(Intent.command("open a new page"), "new-tab")
        XCTAssertEqual(Intent.command("next tab"), "next-tab")
        XCTAssertEqual(Intent.command("go back a tab"), "prev-tab")
        XCTAssertEqual(Intent.command("go to tab three"), "focus-tab 2")
        XCTAssertEqual(Intent.command("close this page"), "close-tab")
    }

    func testRemovedWorkspaceCommandsAreNotExecutable() {
        for said in ["open terminal", "new terminal tab", "show shell", "split this pane down",
                     "divide", "swap pane one with pane two", "make this a file browser", "open agent"] {
            XCTAssertNil(Intent.command(said), said)
        }
        XCTAssertNil(Intent.command("what is the weather like"))
        XCTAssertNil(Intent.command("tab zero"))
    }
}

final class NavigationSafetyTests: XCTestCase {
    func testOrdinarySameSiteNavigationIsAllowed() throws {
        let review = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://shop.example.com/cart")),
            source: try XCTUnwrap(URL(string: "https://www.example.com/products")),
            kind: .link,
            linkText: "View cart"
        )
        XCTAssertEqual(review.disposition, .allow)
        XCTAssertTrue(review.reasons.isEmpty)
    }

    func testActiveContentDestinationsAreBlocked() throws {
        for address in ["javascript:alert(1)", "data:text/html,hello"] {
            let review = NavigationSafety.review(
                destination: try XCTUnwrap(URL(string: address)), source: nil, kind: .link)
            XCTAssertEqual(review.disposition, .block)
            XCTAssertTrue(review.reasons.contains(.activeContentURL))
        }
    }

    func testCredentialsAndPrivateURLPartsNeverReachAdvisoryEvidence() throws {
        let review = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://person:secret@example.com/private?token=hidden#account")),
            source: try XCTUnwrap(URL(string: "https://source.test/start?private=yes")),
            kind: .link
        )
        XCTAssertEqual(review.disposition, .warn)
        XCTAssertTrue(review.reasons.contains(.embeddedCredentials))
        XCTAssertTrue(review.advisoryEvidence.contains("https://example.com"))
        for privateValue in ["person", "secret", "private", "token", "hidden", "account"] {
            XCTAssertFalse(review.advisoryEvidence.contains(privateValue))
        }
    }

    func testDowngradesEncodedHostsAndUnusualPortsWarn() throws {
        let review = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "http://xn--paypl-3ve.test:8080/login")),
            source: try XCTUnwrap(URL(string: "https://bank.test")),
            kind: .link
        )
        XCTAssertEqual(review.disposition, .warn)
        XCTAssertTrue(review.reasons.contains(.insecureDowngrade))
        XCTAssertTrue(review.reasons.contains(.encodedHostname))
        XCTAssertTrue(review.reasons.contains(.unusualPort))
    }

    func testInvalidPortsAreBlocked() throws {
        let review = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://example.test:99999/path")),
            source: nil,
            kind: .link
        )
        XCTAssertEqual(review.disposition, .block)
        XCTAssertTrue(review.reasons.contains(.invalidPort))
    }

    func testCrossSiteFormsAndMisleadingHostTextWarn() throws {
        let source = try XCTUnwrap(URL(string: "https://accounts.example.com/profile"))
        let crossSite = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://collector.test/submit")),
            source: source,
            kind: .form
        )
        XCTAssertTrue(crossSite.reasons.contains(.crossOriginForm))

        let sameSite = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://checkout.example.com/submit")),
            source: source,
            kind: .form
        )
        XCTAssertFalse(sameSite.reasons.contains(.crossOriginForm))

        let misleading = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://paypa1.test/sign-in")),
            source: source,
            kind: .link,
            linkText: "Sign in at paypal.com"
        )
        XCTAssertTrue(misleading.reasons.contains(.misleadingLinkText))
    }

    func testUnexpectedCrossSitePopupDownloadAndRedirectWarn() throws {
        let source = try XCTUnwrap(URL(string: "https://source.test/start"))
        let destination = try XCTUnwrap(URL(string: "https://destination.test/end"))

        XCTAssertTrue(NavigationSafety.review(destination: destination, source: source, kind: .popup).reasons.contains(.crossOriginPopup))
        XCTAssertTrue(NavigationSafety.review(destination: destination, source: source, kind: .download).reasons.contains(.crossOriginDownload))
        XCTAssertTrue(NavigationSafety.review(destination: destination, source: source, kind: .redirect).reasons.contains(.crossSiteRedirect))
    }

}

@MainActor
final class NavigationExceptionStoreTests: XCTestCase {
    func testExceptionsAreExactOriginAndReasonScopedAndRevocable() throws {
        let suite = "NavigationExceptionStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationExceptionStore(defaults: defaults, storageKey: "exceptions")
        let warned = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "https://example.test:8443/path")),
            source: nil,
            kind: .link
        )
        store.allow(warned)
        XCTAssertTrue(store.contains(warned))

        let otherReason = NavigationSafety.review(
            destination: try XCTUnwrap(URL(string: "http://example.test:8443/path")),
            source: try XCTUnwrap(URL(string: "https://source.test")),
            kind: .link
        )
        XCTAssertFalse(store.contains(otherReason))
        store.revoke(try XCTUnwrap(warned.exceptionKey))
        XCTAssertFalse(store.contains(warned))
    }
}

@MainActor
final class WebsitePermissionTests: XCTestCase {
    func testDecisionsAreScopedToTheExactOriginAndPermission() {
        let suite = "WebsitePermissionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WebsitePermissionStore(defaults: defaults, storageKey: "permissions")

        store.set(.allow, for: "https://one.test", kind: .camera)
        store.set(.deny, for: "https://one.test", kind: .microphone)

        XCTAssertEqual(store.decision(for: "https://one.test", kind: .camera), .allow)
        XCTAssertEqual(store.decision(for: "https://one.test", kind: .microphone), .deny)
        XCTAssertNil(store.decision(for: "https://two.test", kind: .camera))
    }

    func testRevokingAPermissionMakesOnlyThatOriginAskAgain() throws {
        let suite = "WebsitePermissionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WebsitePermissionStore(defaults: defaults, storageKey: "permissions")
        store.set(.allow, for: "https://one.test", kind: .location)
        store.set(.allow, for: "https://two.test", kind: .location)

        store.revoke(try XCTUnwrap(store.records.first { $0.key.origin == "https://one.test" }).key)

        XCTAssertNil(store.decision(for: "https://one.test", kind: .location))
        XCTAssertEqual(store.decision(for: "https://two.test", kind: .location), .allow)
    }
}

final class ExternalURLRoutingTests: XCTestCase {
    func testColdLaunchReusesTheBlankPageThenOpensRemainingURLsInOrder() throws {
        let first = try XCTUnwrap(URL(string: "https://example.com/first"))
        let second = try XCTUnwrap(URL(string: "http://localhost:8765/second"))

        XCTAssertEqual(
            ExternalURLRouting.routes(for: [first, second], canReuseActivePage: true),
            [
                ExternalURLRoute(url: first, destination: .reuseActivePage),
                ExternalURLRoute(url: second, destination: .newPage),
            ]
        )
    }

    func testRunningAppOpensEveryDeliveredURLOnceInANewPage() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/repeated"))
        XCTAssertEqual(
            ExternalURLRouting.routes(for: [url, url], canReuseActivePage: false),
            [
                ExternalURLRoute(url: url, destination: .newPage),
                ExternalURLRoute(url: url, destination: .newPage),
            ]
        )
    }

    func testInvalidAndNonWebURLsAreIgnored() throws {
        let valid = try XCTUnwrap(URL(string: "https://example.com"))
        let inputs = [
            try XCTUnwrap(URL(string: "file:///tmp/private")),
            try XCTUnwrap(URL(string: "mailto:person@example.com")),
            try XCTUnwrap(URL(string: "https:///missing-host")),
            valid,
        ]
        XCTAssertEqual(
            ExternalURLRouting.routes(for: inputs, canReuseActivePage: true),
            [ExternalURLRoute(url: valid, destination: .reuseActivePage)]
        )
    }
}

final class BrowserLifecycleTests: XCTestCase {
    func testMemoryPolicyScalesAtTenFiftyAndOneHundredTabs() {
        XCTAssertEqual(TabMemoryPolicy.discardCount(liveCount: 10, pressure: .warning), 2)
        XCTAssertEqual(TabMemoryPolicy.discardCount(liveCount: 50, pressure: .warning), 12)
        XCTAssertEqual(TabMemoryPolicy.discardCount(liveCount: 100, pressure: .warning), 25)
        XCTAssertEqual(TabMemoryPolicy.discardCount(liveCount: 10, pressure: .critical), 6)
        XCTAssertEqual(TabMemoryPolicy.discardCount(liveCount: 50, pressure: .critical), 30)
        XCTAssertEqual(TabMemoryPolicy.discardCount(liveCount: 100, pressure: .critical), 60)
    }

    func testDiscardCandidatesAreOldestFirstAndSkipEveryProtectedTab() {
        let start = Date(timeIntervalSince1970: 1_000)
        let candidates = [
            TabMemoryCandidate(pane: PaneID(1), lastUsed: start.addingTimeInterval(1)),
            TabMemoryCandidate(pane: PaneID(2), lastUsed: start.addingTimeInterval(2), protections: .media),
            TabMemoryCandidate(pane: PaneID(3), lastUsed: start.addingTimeInterval(3), protections: .upload),
            TabMemoryCandidate(pane: PaneID(4), lastUsed: start.addingTimeInterval(4), protections: .download),
            TabMemoryCandidate(pane: PaneID(5), lastUsed: start.addingTimeInterval(5), protections: .unsavedForm),
            TabMemoryCandidate(pane: PaneID(6), lastUsed: start.addingTimeInterval(6), protections: .active),
            TabMemoryCandidate(pane: PaneID(7), lastUsed: start.addingTimeInterval(7)),
        ]
        XCTAssertEqual(TabMemoryPolicy.orderedDiscardCandidates(candidates), [PaneID(1), PaneID(7)])
    }

    func testRapidLifecycleChangesKeepRecoveryBoundToTheRightPage() throws {
        var ledger = TabLifecycleLedger()
        let start = Date(timeIntervalSince1970: 2_000)
        for value in 1...100 {
            ledger.register(PaneID(UInt64(value)), at: start.addingTimeInterval(Double(value)))
        }
        for value in stride(from: 100, through: 1, by: -1) {
            ledger.touch(PaneID(UInt64(value)), at: start.addingTimeInterval(Double(200 - value)))
        }
        for value in stride(from: 10, through: 100, by: 10) {
            let pane = PaneID(UInt64(value))
            let url = try XCTUnwrap(URL(string: "https://example.com/\(value)"))
            ledger.suspend(pane, recovery: BrowserRecovery(
                cause: .webContentTerminated,
                url: url,
                scrollY: Double(value),
                occurredAt: start.addingTimeInterval(300 + Double(value))
            ))
        }

        XCTAssertEqual(ledger.panes.count, 100)
        XCTAssertEqual(ledger.recoveries.count, 10)
        XCTAssertEqual(ledger.takeRecovery(PaneID(50))?.url.absoluteString, "https://example.com/50")
        XCTAssertNil(ledger.recoveries[PaneID(50)])

        for value in 1...50 { ledger.close(PaneID(UInt64(value))) }
        XCTAssertEqual(ledger.panes.count, 50)
        XCTAssertEqual(ledger.recoveries.count, 5)
    }
}

final class DownloadRecordTests: XCTestCase {
    func testDuplicateFilenamesGetANewDestinationWithoutOverwriting() {
        let directory = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)
        let occupied = Set(["/tmp/downloads/report.pdf", "/tmp/downloads/report 2.pdf"])
        let result = DownloadNaming.availableURL(directory: directory, suggestedFilename: "report.pdf") {
            occupied.contains($0)
        }
        XCTAssertEqual(result.path, "/tmp/downloads/report 3.pdf")
    }

    func testSuggestedFilenameCannotEscapeTheDestinationDirectory() {
        XCTAssertEqual(DownloadNaming.sanitized("../../private.txt"), "private.txt")
        XCTAssertEqual(DownloadNaming.sanitized("  "), "Download")
    }

    func testDownloadFailuresExplainCommonServerDiskAndPermissionErrors() {
        XCTAssertEqual(
            DownloadFailure.message(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)),
            "The server returned an invalid response."
        )
        XCTAssertEqual(
            DownloadFailure.message(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)),
            "There is not enough disk space for this download."
        )
        XCTAssertEqual(
            DownloadFailure.message(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)),
            "A file already exists at the chosen destination."
        )
    }
}

final class SurfaceTests: XCTestCase {
    func testTabRowsAreBalancedAndNeverExceedFive() {
        XCTAssertEqual(OpenWork.rows(count: 6).map(\.count), [3, 3])
        XCTAssertEqual(OpenWork.rows(count: 11).map(\.count), [4, 4, 3])
        XCTAssertEqual(OpenWork.rows(count: 5).map(\.count), [5])
        XCTAssertTrue(OpenWork.rows(count: 0).isEmpty)
        for count in 1...100 {
            let rows = OpenWork.rows(count: count)
            let sizes = rows.map(\.count)
            XCTAssertEqual(rows.flatMap { Array($0) }, Array(0..<count))
            XCTAssertLessThanOrEqual(sizes.max()!, 5)
            XCTAssertLessThanOrEqual(sizes.max()! - sizes.min()!, 1)
        }
    }

    func testQuickSwitcherOmitsCurrentTabAndKeepsCreationOrder() {
        let tabs = [Tab(id: TabID(8), pane: PaneID(8)), Tab(id: TabID(2), pane: PaneID(2)), Tab(id: TabID(5), pane: PaneID(5))]
        XCTAssertEqual(OpenWork.switcherTabs(tabs, current: TabID(5)).map(\.id), [TabID(2), TabID(8)])
        XCTAssertEqual(OpenWork.shortcutIndex("1"), 0)
        XCTAssertEqual(OpenWork.shortcutIndex("9"), 8)
        XCTAssertNil(OpenWork.shortcutIndex("0"))
        XCTAssertNil(OpenWork.shortcutIndex("a"))
    }

    func testCleanAddressesPreserveNavigationAndMeaningfulParameters() {
        XCTAssertEqual(CompactLine.editable("https://www.spacex.com/"), "spacex.com")
        let original = "https://www.example.com/a%2Fb?q=C%2B%2B&utm_source=test&fbclid=123#part"
        let clean = "example.com/a%2Fb?q=C%2B%2B#part"
        XCTAssertEqual(CompactLine.editable(original), clean)
        XCTAssertEqual(CompactLine.committed(clean, original: original), original)
        XCTAssertEqual(CompactLine.committed(" other.com ", original: original), "other.com")
        XCTAssertEqual(CompactLine.editable("http://localhost:3000/path"), "http://localhost:3000/path")
        XCTAssertEqual(CompactLine.editable("file:///tmp/page.html"), "file:///tmp/page.html")
        XCTAssertEqual(CompactLine.editable("https://person:password@example.com/"), "example.com")
    }

    func testSearchURLDisplaysTheOriginalWordsAndLiteralPlusSigns() {
        XCTAssertEqual(CompactLine.editable("https://www.google.com/search?q=interlinked+browser&source=abc"), "interlinked browser")
        XCTAssertEqual(CompactLine.editable(address(from: "C++ & café").absoluteString), "C++ & café")
        XCTAssertEqual(Kind.browser.compactLabel(for: address(from: "interlinked browser").absoluteString), "interlinked browser")
        XCTAssertNil(CompactLine.searchQuery("https://google.com.evil.test/search?q=fake"))
        XCTAssertNil(CompactLine.searchQuery("https://example.com/search?q=real"))
    }

    func testGoogleSuggestionsKeepThreeUniqueQueriesInEngineOrder() {
        let data = """
        ["space", ["SpaceX", " spacex ", "space station", "space needle", "space weather"]]
        """.data(using: .utf8)!
        let results = SearchResult.parse(data)
        XCTAssertEqual(results.map(\.title), ["SpaceX", "space station", "space needle"])
        XCTAssertEqual(results.compactMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value },
                       ["SpaceX", "space station", "space needle"])
        XCTAssertTrue(results.allSatisfy { $0.url.host == "www.google.com" && $0.url.path == "/search" })
        XCTAssertTrue(SearchResult.parse(Data("<broken>".utf8)).isEmpty)
    }

    func testBrowserSearchesWordsAndPreservesSearchPunctuation() {
        for query in ["interlinked browser", "weather", "C++ & café #1", "site:paper.design", "what is https://example.com"] {
            let url = address(from: "  " + query + "  ")
            XCTAssertEqual(url.host, "www.google.com")
            XCTAssertEqual(url.path, "/search")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, query)
        }
        XCTAssertTrue(address(from: "C++ tutorial").absoluteString.contains("C%2B%2B"))
    }

    func testBrowserKeepsURLsAndLocalDevelopmentAddresses() {
        XCTAssertEqual(address(from: "paper.design/docs").absoluteString, "https://paper.design/docs")
        XCTAssertEqual(address(from: "https://example.com/a?q=one#two").absoluteString, "https://example.com/a?q=one#two")
        XCTAssertEqual(address(from: "localhost:3000/app").absoluteString, "http://localhost:3000/app")
        XCTAssertEqual(address(from: "127.0.0.1:8080").absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(address(from: "[::1]:8080").absoluteString, "http://[::1]:8080")
        XCTAssertEqual(address(from: "file:///tmp/page.html").scheme, "file")
        XCTAssertEqual(address(from: " \n ").absoluteString, "about:blank")
    }

    func testOpenWorkDistinguishesDocumentsFromTheSameSite() {
        let title = OpenWork.title(customName: nil, pageTitle: "Interlinked explorations", fallback: "paper.design")
        XCTAssertEqual(title, "Interlinked explorations")
        XCTAssertTrue(OpenWork.matches("interlinked paper", title: title, details: ["https://paper.design/123"]))
        XCTAssertFalse(OpenWork.matches("invoice paper", title: title, details: ["https://paper.design/123"]))
    }

    func testOpenWorkKeepsCustomNamesAndHandlesMissingMetadata() {
        XCTAssertEqual(OpenWork.title(customName: " My work ", pageTitle: "Homepage", fallback: "site.test"), "My work")
        XCTAssertEqual(OpenWork.title(customName: nil, pageTitle: " \n ", fallback: "site.test"), "site.test")
        XCTAssertTrue(OpenWork.matches(" \n ", title: "Page", details: []))
        XCTAssertTrue(OpenWork.matches("CAFÉ", title: "Cafe notes", details: []))
    }

    func testAKindIsKnownByMoreThanOneName() {
        XCTAssertEqual(Kind.parse("browser"), .browser)
        XCTAssertEqual(Kind.parse("shell"), .terminal)
        XCTAssertEqual(Kind.parse("file"), .files)
        XCTAssertNil(Kind.parse("interlinked"))
        for kind in Kind.allCases {
            XCTAssertEqual(Kind.parse(kind.name), kind)
        }
    }

    func testSurfacesBelongToPanes() {
        var surfaces = Surfaces()
        XCTAssertEqual(surfaces.kind(PaneID(1)), .blank)
        XCTAssertEqual(surfaces.line(PaneID(1)), "")
        surfaces.setKind(PaneID(1), .browser)
        surfaces.setLine(PaneID(1), "github.com")
        surfaces.setLine(PaneID(2), "~/www")
        XCTAssertEqual(surfaces.kind(PaneID(1)), .browser)
        XCTAssertEqual(surfaces.line(PaneID(1)), "github.com")
        surfaces.setKind(PaneID(1), .terminal)
        XCTAssertEqual(surfaces.line(PaneID(1)), "")
        XCTAssertEqual(surfaces.line(PaneID(2)), "~/www")
        surfaces.forget { $0 == PaneID(1) }
        XCTAssertEqual(surfaces.line(PaneID(2)), "")
    }

    func testATabIsNamedByItsWork() {
        var surfaces = Surfaces()
        var tab = Tab(id: TabID(1), pane: PaneID(1))
        XCTAssertEqual(surfaces.tabTitle(tab), "empty")
        surfaces.setKind(PaneID(1), .terminal)
        XCTAssertEqual(surfaces.tabTitle(tab), "terminal")
        surfaces.setLine(PaneID(1), "~/www")
        XCTAssertEqual(surfaces.tabTitle(tab), "~/www")
        surfaces.setKind(PaneID(1), .browser)
        surfaces.setLine(PaneID(1), "https://paper.design/")
        XCTAssertEqual(surfaces.tabTitle(tab), "paper.design")
        tab.name = "work"
        XCTAssertEqual(surfaces.tabTitle(tab), "work")
    }
}

final class ThemeTests: XCTestCase {
    func testASidebarSettlesOntoARealWidthOrCollapses() {
        XCTAssertEqual(Metrics.settleSidebar(80), 0)
        XCTAssertEqual(Metrics.settleSidebar(Metrics.sidebarCollapse - 1), 0)
        XCTAssertEqual(Metrics.settleSidebar(140), Metrics.sidebarMin)
        XCTAssertEqual(Metrics.settleSidebar(216), 216)
        XCTAssertEqual(Metrics.settleSidebar(800), Metrics.sidebarMax)
    }
}

final class BrowserMigrationTests: XCTestCase {
    func testSplitPagesBecomeTabsAndKeepTheirURLsAndSelection() {
        var split = Tab(id: TabID(5), pane: PaneID(10))
        _ = split.split(PaneID(10), axis: .columns, new: PaneID(11), id: SplitID(1))
        split.name = "Reference"
        var old = Session(version: 1, tabs: [split, Tab(id: TabID(6), pane: PaneID(12))], active: 0,
            next_tab: 7, next_pane: 14, next_split: 2,
            surfaces: [SurfacePair(pane: PaneID(10), surface: Surface(kind: .browser, line: "https://one.test/a")),
                       SurfacePair(pane: PaneID(11), surface: Surface(kind: .browser, line: "https://two.test/b")),
                       SurfacePair(pane: PaneID(12), surface: Surface(kind: .terminal, line: "/tmp")),
                       SurfacePair(pane: PaneID(13), surface: Surface(kind: .terminal, line: "/Users/jow"))],
            tint: .ink, sidebar: 0, sidebar_last: 216)
        old = old.browserOnly()
        XCTAssertEqual(old.tabs.count, 2)
        XCTAssertEqual(old.tabs[old.active].active, PaneID(11))
        XCTAssertEqual(old.tabs[old.active].id, TabID(5))
        XCTAssertEqual(old.tabs[old.active].name, "Reference")
        XCTAssertEqual(Set(old.tabs.map(\.id)).count, 2)
        XCTAssertTrue(old.tabs.allSatisfy { $0.root == .leaf($0.active) })
        XCTAssertEqual(old.surfaces.map { $0.surface.line }, ["https://one.test/a", "https://two.test/b"])
        XCTAssertTrue(old.surfaces.allSatisfy { $0.surface.kind == .browser })
        let again = old.browserOnly()
        XCTAssertEqual(again.tabs, old.tabs)
        XCTAssertEqual(again.active, old.active)
        XCTAssertEqual(again.next_tab, old.next_tab)
    }

    func testLegacyTerminalFieldsDecodeWithoutRestoringAShell() throws {
        let json = #"{"version":1,"tabs":[],"active":0,"next_tab":1,"next_pane":2,"next_split":1,"surfaces":[],"terminal_open":true,"terminal_height":220,"terminal_pane":1}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8)).browserOnly()
        XCTAssertTrue(session.isKnown)
        XCTAssertTrue(session.tabs.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        XCTAssertFalse(encoded.contains("terminal"))
    }
}

final class DomainIconCacheTests: XCTestCase {
    func testSameDomainSharesOneRequestAndCachedImage() throws {
        var cache = DomainIconCache<String>()
        _ = cache.retain([PaneID(1): "example.com", PaneID(2): "example.com"])
        let token = try XCTUnwrap(cache.begin("example.com"))
        XCTAssertNil(cache.begin("example.com"))
        XCTAssertTrue(cache.complete("example.com", token: token, value: "icon"))
        XCTAssertEqual(cache.value(for: PaneID(1)), "icon")
        XCTAssertEqual(cache.value(for: PaneID(2)), "icon")
        _ = cache.retain([PaneID(1): "example.com", PaneID(2): "example.com", PaneID(3): "example.com"])
        XCTAssertEqual(cache.value(for: PaneID(3)), "icon")
        XCTAssertNil(cache.begin("example.com"))
    }

    func testRestoredImageSkipsANewRequest() {
        var cache = DomainIconCache<String>()
        _ = cache.retain([PaneID(1): "example.com"])
        XCTAssertTrue(cache.restore("example.com", value: "saved icon"))
        XCTAssertEqual(cache.value(for: PaneID(1)), "saved icon")
        XCTAssertNil(cache.begin("example.com"))
        XCTAssertFalse(cache.restore("example.com", value: "replacement"))
        XCTAssertFalse(cache.restore("closed.example", value: "unused"))
    }

    func testRetainedByOtherTabsAndReleasedAfterLastTabLeaves() throws {
        var cache = DomainIconCache<String>()
        _ = cache.retain([PaneID(1): "example.com", PaneID(2): "example.com"])
        let token = try XCTUnwrap(cache.begin("example.com"))
        cache.complete("example.com", token: token, value: "icon")
        XCTAssertTrue(cache.retain([PaneID(2): "example.com"]).isEmpty)
        XCTAssertEqual(cache.value(for: PaneID(2)), "icon")
        XCTAssertEqual(cache.retain([PaneID(2): "other.com"]), ["example.com"])
        XCTAssertNil(cache.value(for: PaneID(2)))
        _ = cache.retain([PaneID(3): "example.com"])
        let next = try XCTUnwrap(cache.begin("example.com"))
        XCTAssertNotEqual(next, token)
        XCTAssertFalse(cache.complete("example.com", token: token, value: "stale"))
        XCTAssertTrue(cache.complete("example.com", token: next, value: "fresh"))
        XCTAssertEqual(cache.value(for: PaneID(3)), "fresh")
    }

    func testFailedLookupDoesNotRefetchUntilDomainIsClosed() throws {
        var cache = DomainIconCache<String>()
        _ = cache.retain([PaneID(1): "example.com"])
        let token = try XCTUnwrap(cache.begin("example.com"))
        cache.complete("example.com", token: token, value: nil)
        XCTAssertNil(cache.begin("example.com"))
        _ = cache.retain([:])
        _ = cache.retain([PaneID(1): "example.com"])
        XCTAssertNotNil(cache.begin("example.com"))
    }

    func testDomainIgnoresPathAndQueryButKeepsDistinctHosts() {
        XCTAssertEqual(DomainIconCache<String>.domain(URL(string: "https://EXAMPLE.com/a?b=1")), "example.com")
        XCTAssertEqual(DomainIconCache<String>.domain(URL(string: "http://example.com/b")), "example.com")
        XCTAssertEqual(DomainIconCache<String>.domain(URL(string: "https://studio.example.com/")), "studio.example.com")
        XCTAssertNil(DomainIconCache<String>.domain(URL(string: "file:///tmp/page.html")))
    }


}

@MainActor
final class SiteMenuPolicyTests: XCTestCase {
    func testPublicPagesWithAShortSameSiteListAreAccepted() {
        let menu = SiteMenu(
            home: "https://www.spacex.com/",
            items: [
                SiteMenuItem(id: "1", label: "Vehicles", href: "https://www.spacex.com/vehicles", current: false, children: [
                    SiteMenuItem(id: "1a", label: "Falcon 9", href: "https://www.spacex.com/vehicles/falcon-9", current: false)
                ]),
                SiteMenuItem(id: "2", label: "Human Spaceflight", href: "https://www.spacex.com/human-spaceflight", current: true),
                SiteMenuItem(id: "3", label: "Starlink", href: "https://www.spacex.com/starlink", current: false),
                SiteMenuItem(id: "4", label: "Starshield", href: "https://www.spacex.com/starshield", current: false)
            ],
            search: SiteMenuSearch(action: "https://www.spacex.com/search", placeholder: "Search", queryParam: "q"),
            height: 64
        )
        let accepted = SiteMenuPolicy.accept(menu)
        XCTAssertEqual(accepted?.items.count, 4)
        XCTAssertEqual(accepted?.items.first?.children.first?.label, "Falcon 9")
        XCTAssertEqual(accepted?.search?.queryParam, "q")
        let noisy = SiteMenu(
            home: "https://github.com/",
            items: [SiteMenuItem(id: "1", label: "Dashboard", href: "https://github.com/", current: true)],
            search: SiteMenuSearch(action: "https://github.com/search", placeholder: "Open quick search dialog, type / to search", queryParam: "q"),
            height: 56
        )
        XCTAssertEqual(SiteMenuPolicy.accept(noisy)?.search?.placeholder, "Search")
    }

    func testSignedInDashboardsAndIconBarsAreAccepted() {
        let github = SiteMenu(
            home: "https://github.com/",
            items: [
                SiteMenuItem(id: "1", label: "Dashboard", href: "https://github.com/", current: true),
                SiteMenuItem(id: "2", label: "Create new", href: "", kind: "button", current: false),
                SiteMenuItem(id: "3", label: "Issues", href: "https://github.com/issues", current: false)
            ],
            search: SiteMenuSearch(action: "https://github.com/search", placeholder: "Type / to search", queryParam: "q"),
            height: 56
        )
        XCTAssertEqual(SiteMenuPolicy.accept(github)?.items.count, 3)
        let iconOnly = SiteMenuItem(id: "i", label: "", href: "", kind: "button", current: false, title: "Issues", icon: "data:image/svg+xml,test", iconKind: "svg")
        let withoutIcons = SiteMenuPolicy.accept(SiteMenu(
            home: "https://github.com/",
            items: [
                SiteMenuItem(id: "1", label: "Dashboard", href: "https://github.com/", current: true),
                iconOnly
            ],
            height: 56,
            replacesChrome: true
        ))
        XCTAssertEqual(withoutIcons?.items.map(\.label), ["Dashboard"])
        XCTAssertEqual(withoutIcons?.replacesChrome, true)
        let searchOnly = SiteMenu(
            home: "https://github.com/",
            items: [SiteMenuItem(id: "1", label: "Dashboard", href: "https://github.com/", current: true)],
            search: SiteMenuSearch(action: "https://github.com/search", placeholder: "Search", queryParam: "q"),
            height: 56
        )
        XCTAssertNotNil(SiteMenuPolicy.accept(searchOnly))
    }

    func testEveryWebPageKeepsAMenu() {
        let few = SiteMenu(home: "https://www.example.com/", name: "Example", items: [
            SiteMenuItem(id: "1", label: "Home", href: "https://www.example.com/", current: true)
        ], height: 48, replacesChrome: true)
        let accepted = SiteMenuPolicy.accept(few)
        XCTAssertEqual(accepted?.items.map(\.label), ["Home"])
        XCTAssertEqual(accepted?.name, "Example")
        XCTAssertEqual(accepted?.replacesChrome, true)
        let unnamed = SiteMenuPolicy.accept(SiteMenu(
            home: "https://www.example.com/",
            items: [
                SiteMenuItem(id: "a", label: "", href: "", current: false),
                SiteMenuItem(id: "b", label: "", href: "javascript:void(0)", current: false)
            ],
            height: 48,
            replacesChrome: true
        ))
        XCTAssertEqual(unnamed?.items.count, 0)
        XCTAssertEqual(unnamed?.name, "example.com")
        XCTAssertEqual(unnamed?.replacesChrome, false)
        XCTAssertNil(SiteMenuPolicy.accept(SiteMenu(home: "javascript:void(0)", items: [
            SiteMenuItem(id: "1", label: "Home", href: "https://example.com/", current: true)
        ], height: 40)))
        let many = (0..<30).map {
            SiteMenuItem(id: "\($0)", label: "Item \($0)", href: "https://example.com/\($0)", current: false)
        }
        XCTAssertEqual(SiteMenuPolicy.accept(SiteMenu(home: "https://example.com/", items: many, height: 48))?.items.count, 24)
        let google = SiteMenuPolicy.baseline(line: "https://www.google.com/search?q=google")
        XCTAssertEqual(google?.home, "https://www.google.com/")
        XCTAssertEqual(google?.name, "google.com")
        XCTAssertEqual(google?.items.count, 0)
        XCTAssertEqual(google?.replacesChrome, false)
        XCTAssertNil(SiteMenuPolicy.baseline(line: ""))
        XCTAssertNil(SiteMenuPolicy.baseline(line: "about:blank"))
        XCTAssertEqual(SiteMenuLayout.visibleCount(itemWidths: [80, 80, 80, 80, 80, 80], budget: 10_000), 5)
        XCTAssertEqual(SiteMenuLayout.visibleCount(itemWidths: [100, 100, 100], budget: 200, moreWidth: 64), 1)
        XCTAssertEqual(SiteMenuLayout.visibleCount(itemWidths: [80, 80], budget: 200, moreWidth: 64), 2)
        XCTAssertEqual(SiteMenuLayout.visibleCount(itemWidths: [500], budget: 100, moreWidth: 64), 0)
    }

    func testBridgeCanHideAndRestoreADetectedBanner() {
        XCTAssertTrue(PageTextBridge.install.contains("siteMenu()"))
        XCTAssertTrue(PageTextBridge.install.contains("hideSiteMenu()"))
        XCTAssertTrue(PageTextBridge.install.contains("showSiteMenu()"))
        XCTAssertTrue(PageTextBridge.install.contains("interlinkedSiteMenu"))
        XCTAssertTrue(PageTextBridge.install.contains("document.body.children"))
        XCTAssertFalse(PageTextBridge.install.contains("querySelectorAll('body *')"))
        XCTAssertTrue(PageTextBridge.install.contains("visibility','hidden','important'"))
        XCTAssertTrue(PageTextBridge.install.contains("interlinked-site-menu-spacer"))
        XCTAssertTrue(PageTextBridge.install.contains("inBar"))
        XCTAssertTrue(PageTextBridge.install.contains("next.score"))
        XCTAssertTrue(PageTextBridge.install.contains("replacesChrome"))
        XCTAssertTrue(PageTextBridge.install.contains("og:site_name"))
        XCTAssertFalse(PageTextBridge.install.contains("captureIcon"))
        XCTAssertFalse(PageTextBridge.install.contains("next.items.length>best.items.length"))
        XCTAssertTrue(PageTextBridge.install.contains("hideSiteMenu()"))
    }

    func testSiteMenuDefaultsOnAndCanBeTurnedOff() {
        let suite = "site-menu-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(SiteMenuPreference.enabled(in: defaults))
        SiteMenuPreference.set(false, in: defaults)
        XCTAssertFalse(SiteMenuPreference.enabled(in: defaults))
    }
}

final class DomainIconStoreTests: XCTestCase {
    func testSavedDataSurvivesANewStoreInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let saved = Data([0, 1, 2, 3])
        try DomainIconStore(directory: directory).write(saved, for: "example.com")

        let restarted = DomainIconStore(directory: directory)
        XCTAssertEqual(restarted.data(for: "example.com"), saved)
        XCTAssertNil(restarted.data(for: "other.example"))
    }

    func testRemovingOneDomainLeavesOtherDomainsAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DomainIconStore(directory: directory)
        try store.write(Data([1]), for: "one.example")
        try store.write(Data([2]), for: "two.example")

        store.remove("one.example")

        XCTAssertNil(store.data(for: "one.example"))
        XCTAssertEqual(store.data(for: "two.example"), Data([2]))
    }
}
