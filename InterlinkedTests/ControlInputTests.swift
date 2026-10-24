import AppKit
import XCTest

final class ControlKeyTests: XCTestCase {
    func testNamedKeysCarryTheirCodeAndCharacter() {
        let escape = ControlKey.parse(["escape"])
        XCTAssertEqual(escape?.keyCode, 53)
        XCTAssertEqual(escape?.characters, "\u{1B}")
        XCTAssertEqual(escape?.modifiers, [])
        XCTAssertEqual(ControlKey.parse(["esc"]), escape)
        XCTAssertEqual(ControlKey.parse(["up"])?.keyCode, 126)
        XCTAssertEqual(ControlKey.parse(["tab"])?.characters, "\t")
        XCTAssertEqual(ControlKey.parse(["backslash", "cmd"]), ControlKey.parse(["\\", "cmd"]))
        XCTAssertEqual(ControlKey.parse(["comma"])?.characters, ",")
    }

    func testModifiersCanBeWordsOrJoinedWithPlus() {
        let spaced = ControlKey.parse(["g", "cmd", "shift"])
        let joined = ControlKey.parse(["cmd+shift+g"])
        XCTAssertEqual(spaced, joined)
        XCTAssertEqual(joined?.keyCode, 5)
        XCTAssertEqual(joined?.modifiers, [.command, .shift])
        XCTAssertEqual(joined?.charactersIgnoringModifiers.lowercased(), "g", "the app lowercases before matching")
        XCTAssertEqual(ControlKey.parse(["\\", "command", "option"])?.modifiers, [.command, .option])
        XCTAssertEqual(ControlKey.parse(["Tab", "CTRL"])?.modifiers, [.control])
    }

    func testLongNumbersAreKeyCodesAndSingleDigitsAreDigits() {
        XCTAssertEqual(ControlKey.parse(["53"]), ControlKey.parse(["escape"]))
        let one = ControlKey.parse(["1", "cmd"])
        XCTAssertEqual(one?.keyCode, 18)
        XCTAssertEqual(one?.characters, "1")
        let unknown = ControlKey.parse(["99"])
        XCTAssertEqual(unknown?.keyCode, 99)
        XCTAssertEqual(unknown?.characters, "")
    }

    func testNeedsExactlyOneKnownKey() {
        XCTAssertNil(ControlKey.parse([]))
        XCTAssertNil(ControlKey.parse(["cmd"]))
        XCTAssertNil(ControlKey.parse(["f", "g"]))
        XCTAssertNil(ControlKey.parse(["hyper", "f"]))
        XCTAssertNil(ControlKey.parse(["99999999"]))
    }
}

final class ControlSettingTests: XCTestCase {
    func testSwitchesTakeOnOrOff() {
        for setting in ControlSetting.allCases where setting.choices == ["on", "off"] {
            XCTAssertEqual(setting.parse("on"), .bool(true))
            XCTAssertEqual(setting.parse("OFF"), .bool(false))
            XCTAssertEqual(setting.parse("true"), .bool(true))
            XCTAssertEqual(setting.parse("0"), .bool(false))
            XCTAssertNil(setting.parse("maybe"))
        }
    }

    func testChoicesMatchTheirPreferences() {
        XCTAssertEqual(ControlSetting.darkPages.choices, ["off", "system", "always"])
        XCTAssertEqual(ControlSetting.darkPages.parse("always"), .choice("always"))
        XCTAssertNil(ControlSetting.darkPages.parse("on"))
        for setting in ControlSetting.allCases {
            for choice in setting.choices {
                XCTAssertNotNil(setting.parse(choice), "\(setting.rawValue) accepts its own \(choice)")
            }
        }
    }

    func testNamesAreStable() {
        XCTAssertEqual(ControlSetting(rawValue: "useful-info.address"), .usefulAddress)
        XCTAssertEqual(ControlSetting(rawValue: "jev"), .jev)
        XCTAssertNil(ControlSetting(rawValue: "usefulInfo.address"))
    }
}
