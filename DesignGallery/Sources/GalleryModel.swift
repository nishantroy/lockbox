import SwiftUI

@MainActor
final class GalleryModel: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable {
        // Round 1 references remain available for direct comparison.
        case midnight
        case circadian
        case lantern
        // Round 2 choices are gallery-only explorations.
        case midnightOriginal
        case midnightContrast
        case adaptivePreview

        static let round1: [Theme] = [.midnight, .circadian, .lantern]
        static let round2: [Theme] = [.midnightOriginal, .midnightContrast, .adaptivePreview]

        var id: String { rawValue }

        var title: String {
            switch self {
            case .midnight: "Round 1 · Midnight Sanctuary"
            case .circadian: "Round 1 · Circadian Calm"
            case .lantern: "Round 1 · Soft Lantern"
            case .midnightOriginal: "Round 2 · Midnight Original"
            case .midnightContrast: "Round 2 · Midnight Contrast"
            case .adaptivePreview: "Round 2 · Adaptive Preview · future"
            }
        }

        var shortTitle: String {
            switch self {
            case .midnight: "Midnight"
            case .circadian: "Circadian"
            case .lantern: "Lantern"
            case .midnightOriginal: "Original"
            case .midnightContrast: "Contrast"
            case .adaptivePreview: "Adaptive"
            }
        }

        var isAdaptivePreview: Bool { self == .adaptivePreview }

        var isRoundTwo: Bool { Self.round2.contains(self) }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case dark
        case light

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dark: "Dark"
            case .light: "Light"
            }
        }
    }

    enum Fixture: String, CaseIterable, Identifiable {
        case home
        case rest
        case focus

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: "Home · unlocked"
            case .rest: "Get some rest · active"
            case .focus: "Focus time · active"
            }
        }

        var shortTitle: String {
            switch self {
            case .home: "Home"
            case .rest: "Rest"
            case .focus: "Focus"
            }
        }
    }

    @Published var theme: Theme
    @Published var fixture: Fixture
    @Published var appearance: Appearance

    init(theme: Theme = .midnight, fixture: Fixture = .home, appearance: Appearance = .dark) {
        self.theme = theme
        self.fixture = fixture
        self.appearance = appearance
    }

    static func fromLaunchArguments() -> GalleryModel {
        let arguments = ProcessInfo.processInfo.arguments
        let theme = value(after: "-gallery-theme", in: arguments)
            .flatMap(Theme.init(rawValue:)) ?? .midnight
        let fixture = value(after: "-gallery-fixture", in: arguments)
            .flatMap(Fixture.init(rawValue:)) ?? .home
        let appearance = value(after: "-gallery-appearance", in: arguments)
            .flatMap(Appearance.init(rawValue:)) ?? .dark
        return GalleryModel(theme: theme, fixture: fixture, appearance: appearance)
    }

    private static func value(after key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
