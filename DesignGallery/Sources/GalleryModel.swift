import SwiftUI

@MainActor
final class GalleryModel: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable {
        case midnight
        case circadian
        case lantern

        var id: String { rawValue }

        var title: String {
            switch self {
            case .midnight: "Midnight Sanctuary"
            case .circadian: "Circadian Calm"
            case .lantern: "Soft Lantern"
            }
        }

        var shortTitle: String {
            switch self {
            case .midnight: "Midnight"
            case .circadian: "Circadian"
            case .lantern: "Lantern"
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

    init(theme: Theme = .midnight, fixture: Fixture = .home) {
        self.theme = theme
        self.fixture = fixture
    }

    static func fromLaunchArguments() -> GalleryModel {
        let arguments = ProcessInfo.processInfo.arguments
        let theme = value(after: "-gallery-theme", in: arguments)
            .flatMap(Theme.init(rawValue:)) ?? .midnight
        let fixture = value(after: "-gallery-fixture", in: arguments)
            .flatMap(Fixture.init(rawValue:)) ?? .home
        return GalleryModel(theme: theme, fixture: fixture)
    }

    private static func value(after key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
