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
        guard marks.count > 1, let last = marks.last else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    /// Header subline: "No trusted people yet", "1 trusted person",
    /// "2 trusted people", plus " · helping 1" when the user also helps someone.
    public static func summary(trustedCount: Int, helpingCount: Int) -> String {
        let base: String
        switch trustedCount {
        case ..<1: base = "No trusted people yet"
        case 1: base = "1 trusted person"
        default: base = "\(trustedCount) trusted people"
        }
        return helpingCount > 0 ? "\(base) · helping \(helpingCount)" : base
    }
}
