import SwiftUI

/// A 36 pt circle in `rest` at about 20% fill with the person's initials.
/// Decorative: the name is always next to it, so VoiceOver skips it.
struct LockboxAvatar: View {
    let name: String
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 36

    var body: some View {
        Text(PeopleDisplay.initials(for: name))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LockboxTheme.rest)
            .frame(width: size, height: size)
            .background(LockboxTheme.rest.opacity(0.2), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Sentence-case capsule marking a prototype feature (not the uppercase status badge).
struct LockboxPrototypeBadge: View {
    var body: some View {
        Text("Prototype")
            .font(.caption.weight(.semibold))
            .foregroundStyle(LockboxTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(LockboxTheme.surface, in: Capsule())
            .overlay { Capsule().stroke(LockboxTheme.border.opacity(0.75), lineWidth: 1) }
    }
}

extension View {
    /// A dashed hairline outline for prototype-only controls (design language §6.5).
    func lockboxPrototypeOutline(cornerRadius: CGFloat = LockboxTheme.controlCornerRadius) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LockboxTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .allowsHitTesting(false)
        }
    }
}
