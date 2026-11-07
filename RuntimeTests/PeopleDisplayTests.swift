import XCTest
@testable import PhoneLockboxRuntime

final class PeopleDisplayTests: XCTestCase {
    func testInitialsTwoWords() {
        XCTAssertEqual(PeopleDisplay.initials(for: "Ari Stone"), "AS")
        XCTAssertEqual(PeopleDisplay.initials(for: "  dana   lee  "), "DL")
    }

    func testInitialsThreeWordsUsesFirstAndLast() {
        XCTAssertEqual(PeopleDisplay.initials(for: "Mary Jane Watson"), "MW")
    }

    func testInitialsOneWord() {
        XCTAssertEqual(PeopleDisplay.initials(for: "Ari"), "A")
        XCTAssertEqual(PeopleDisplay.initials(for: "ari"), "A")
    }

    func testInitialsEmojiAndEmptyFallBack() {
        XCTAssertEqual(PeopleDisplay.initials(for: ""), "?")
        XCTAssertEqual(PeopleDisplay.initials(for: "   "), "?")
        XCTAssertEqual(PeopleDisplay.initials(for: "😀"), "?")
        XCTAssertEqual(PeopleDisplay.initials(for: "😀 Sam"), "S")
    }

    func testInitialsNonLatin() {
        XCTAssertEqual(PeopleDisplay.initials(for: "李雷"), "李")
        XCTAssertEqual(PeopleDisplay.initials(for: "Анна Иванова"), "АИ")
        XCTAssertEqual(PeopleDisplay.initials(for: "محمد علي"), "مع")
    }

    func testInitialsHyphenDigitsEszettAndDefaultNames() {
        XCTAssertEqual(PeopleDisplay.initials(for: "Anne-Marie"), "A")
        XCTAssertEqual(PeopleDisplay.initials(for: "Mary-Jane Watson"), "MW")
        XCTAssertEqual(PeopleDisplay.initials(for: "42"), "4")
        XCTAssertEqual(PeopleDisplay.initials(for: "ß"), "S")
        XCTAssertEqual(PeopleDisplay.initials(for: "Someone"), "S")
        XCTAssertEqual(PeopleDisplay.initials(for: "The other person"), "TP")
    }

    func testSummaryNobody() {
        XCTAssertEqual(PeopleDisplay.summary(activeCount: 0, listedCount: 0, helpingCount: 0), "No trusted people yet")
    }

    func testSummaryActive() {
        XCTAssertEqual(PeopleDisplay.summary(activeCount: 1, listedCount: 1, helpingCount: 0), "1 trusted person")
        XCTAssertEqual(PeopleDisplay.summary(activeCount: 2, listedCount: 3, helpingCount: 0), "2 trusted people")
    }

    func testSummaryListedButNoneActive() {
        XCTAssertEqual(PeopleDisplay.summary(activeCount: 0, listedCount: 1, helpingCount: 0), "No active trusted people")
        XCTAssertEqual(PeopleDisplay.summary(activeCount: 0, listedCount: 1, settingUpCount: 1, helpingCount: 0),
                       "No active trusted people · 1 setting up")
    }

    func testSummarySettingUpAndHelping() {
        XCTAssertEqual(PeopleDisplay.summary(activeCount: 2, listedCount: 3, settingUpCount: 1, helpingCount: 1),
                       "2 trusted people · 1 setting up · helping 1 person")
        XCTAssertEqual(PeopleDisplay.summary(activeCount: 1, listedCount: 1, helpingCount: 2),
                       "1 trusted person · helping 2 people")
    }

    func testSummaryOnlyHelping() {
        XCTAssertEqual(PeopleDisplay.summary(activeCount: 0, listedCount: 0, helpingCount: 2), "Helping 2 people")
        XCTAssertEqual(PeopleDisplay.summary(activeCount: 0, listedCount: 0, helpingCount: 1), "Helping 1 person")
    }
}
