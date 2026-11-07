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

    func testSummary() {
        XCTAssertEqual(PeopleDisplay.summary(trustedCount: 0, helpingCount: 0), "No trusted people yet")
        XCTAssertEqual(PeopleDisplay.summary(trustedCount: 1, helpingCount: 0), "1 trusted person")
        XCTAssertEqual(PeopleDisplay.summary(trustedCount: 2, helpingCount: 0), "2 trusted people")
        XCTAssertEqual(PeopleDisplay.summary(trustedCount: 2, helpingCount: 1), "2 trusted people · helping 1")
        XCTAssertEqual(PeopleDisplay.summary(trustedCount: 0, helpingCount: 2), "No trusted people yet · helping 2")
    }
}
