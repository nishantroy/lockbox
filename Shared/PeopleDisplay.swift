import Foundation

/// Pure display helpers for the People tab. Kept in Shared so they can be
/// unit-tested without SwiftUI.
public enum PeopleDisplay {
    /// Avatar initials: the first letter or digit of the first and last words
    /// (two words or more), or of the only word. Emoji, punctuation and empty
    /// names fall back to "?". Uppercased, so "ari" reads "A".
    public static func initials(for name: String) -> String {
        let marks = name
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { word in word.first(where: { $0.isLetter || $0.isNumber }) }
        guard let first = marks.first else { return "?" }
        // One character each: "ß".uppercased() is "SS".
        func mark(_ c: Character) -> String { String(String(c).uppercased().prefix(1)) }
        guard marks.count > 1, let last = marks.last else { return mark(first) }
        return mark(first) + mark(last)
    }

    /// Header subline from accurate state.
    /// - `activeCount`: people the user invited who are fully trusted.
    /// - `listedCount`: everyone the user invited who is listed, in any state.
    /// - `settingUpCount`: listed people who joined but haven't finished setup.
    /// - `helpingCount`: people the user is a trusted person for.
    ///
    /// Examples: "2 trusted people · 1 setting up · helping 1 person",
    /// "No trusted people yet", "No active trusted people" (listed, none
    /// active), "Helping 2 people" (the user only helps others).
    public static func summary(activeCount: Int, listedCount: Int, settingUpCount: Int = 0, helpingCount: Int) -> String {
        let helping: String? = helpingCount > 0
            ? "helping \(helpingCount) \(helpingCount == 1 ? "person" : "people")"
            : nil
        if activeCount < 1, listedCount < 1 {
            guard let helping else { return "No trusted people yet" }
            return helping.prefix(1).uppercased() + helping.dropFirst()
        }
        var parts: [String]
        switch activeCount {
        case ..<1: parts = ["No active trusted people"]
        case 1: parts = ["1 trusted person"]
        default: parts = ["\(activeCount) trusted people"]
        }
        if settingUpCount > 0 { parts.append("\(settingUpCount) setting up") }
        if let helping { parts.append(helping) }
        return parts.joined(separator: " · ")
    }
}
