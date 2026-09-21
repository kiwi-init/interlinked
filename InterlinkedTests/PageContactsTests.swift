import XCTest

final class PageContactsTests: XCTestCase {
    func testStructuredAddressWinsAndContactsDeduplicate() {
        let signals = PageContactSignals(
            structuredAddresses: ["1 Infinite Loop,  Cupertino, CA, 95014"],
            addressElements: [],
            phones: ["+1 408-555-0100", "+14085550100"],
            emails: ["Hello@Example.com", "hello@example.com", "not an email"],
            text: ""
        )
        let found = PageContactDetector.contacts(from: signals)
        XCTAssertEqual(found.address, "1 Infinite Loop, Cupertino, CA, 95014")
        XCTAssertEqual(found.phones, ["+1 408-555-0100"])
        XCTAssertEqual(found.emails, ["Hello@Example.com"])
        XCTAssertEqual(found.options.map(\.kind), [.phone, .email])
    }

    func testDetectsAddressPhoneAndEmailInContactText() {
        let signals = PageContactSignals(text: """
        Visit us
        1 Infinite Loop
        Cupertino, CA 95014
        Call (408) 555-0100 or write to support@example.com
        """)
        let found = PageContactDetector.contacts(from: signals)
        XCTAssertEqual(found.address.map { $0.contains("Infinite Loop") }, true)
        XCTAssertEqual(found.phones.count, 1)
        XCTAssertEqual(found.emails, ["support@example.com"])
    }

    func testAddressElementsWithoutAnAddressAreIgnored() {
        let signals = PageContactSignals(addressElements: ["Written by Jane, jane@example.com"])
        XCTAssertNil(PageContactDetector.contacts(from: signals).address)
    }

    func testOptionsAreLimited() {
        let phones = (0..<6).map { "+1 408-555-010\($0)" }
        let found = PageContactDetector.contacts(from: PageContactSignals(phones: phones))
        XCTAssertEqual(found.phones.count, PageContactDetector.maximumOptions)
        XCTAssertTrue(PageContacts().isEmpty)
    }

    func testShieldRunsBeforePaintAndCanStop() {
        XCTAssertTrue(SharingScreenShield.script.contains("new MutationObserver"))
        XCTAssertTrue(SharingScreenShield.script.contains("CSS.highlights.set(NAME, highlight)"))
        XCTAssertTrue(SharingScreenShield.script.contains("stop()"))
        XCTAssertEqual(SharingScreenShield.stopScript, "globalThis.__interlinkedShield?.stop();")
    }
}
