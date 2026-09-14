import SwiftUI

enum LockboxActionEmphasis: Equatable {
    case primary
    case secondary
    case destructive
}

/// A full-width action treatment with an unmistakable touch-down state.
/// Navigation rows and toolbar controls intentionally keep their system styles.
struct LockboxActionButtonStyle: ButtonStyle {
    let emphasis: LockboxActionEmphasis
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 14)
            .foregroundStyle(foregroundColor)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(backgroundColor)
            }
            .overlay {
                if emphasis != .primary {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.12 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch emphasis {
        case .primary: LockboxTheme.onAccent
        case .secondary: LockboxTheme.accent
        case .destructive: LockboxTheme.destructive
        }
    }

    private var backgroundColor: Color {
        switch emphasis {
        case .primary: LockboxTheme.accent
        case .secondary: LockboxTheme.accent.opacity(0.1)
        case .destructive: LockboxTheme.destructive.opacity(0.1)
        }
    }

    private var borderColor: Color {
        switch emphasis {
        case .primary: .clear
        case .secondary: LockboxTheme.accent.opacity(0.35)
        case .destructive: LockboxTheme.destructive.opacity(0.35)
        }
    }
}
