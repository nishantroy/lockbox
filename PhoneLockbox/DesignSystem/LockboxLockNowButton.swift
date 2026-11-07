import SwiftUI

/// The hero "Lock now" control on the Open screen: a large round button with a
/// soft, static halo. It never animates on its own; only touch-down feedback.
struct LockboxLockNowButton: View {
    let action: () -> Void
    @ScaledMetric(relativeTo: .title) private var baseDiameter: CGFloat = 184
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(LockboxLockNowButtonStyle(baseDiameter: baseDiameter))
        .accessibilityLabel("Lock now")
        .accessibilityHint(isEnabled ? "Choose a finite focus lock duration" : "Needs Screen Time access")
        .saturation(isEnabled ? 1 : 0.3)
        .opacity(isEnabled ? 1 : 0.5)
        .frame(maxWidth: .infinity)
    }
}

private struct LockboxLockNowButtonStyle: ButtonStyle {
    let baseDiameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        Circle()
            .fill(LockboxTheme.rest)
            .containerRelativeFrame(.horizontal) { width, _ in
                min(baseDiameter, width * 0.6)
            }
            .aspectRatio(1, contentMode: .fit)
            .background {
                Circle()
                    .fill(LockboxTheme.rest.opacity(0.25))
                    .scaleEffect(1.12)
                    .blur(radius: 16)
                    .containerRelativeFrame(.horizontal) { width, _ in
                        min(baseDiameter, width * 0.6)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityHidden(true)
            }
            .overlay {
                // Sized from the clamped diameter the circle actually received.
                GeometryReader { proxy in
                    VStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: proxy.size.width * 0.24, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("Lock now")
                            .font(.title3.weight(.semibold))
                    }
                    .foregroundStyle(LockboxTheme.onAccent)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .contentShape(Circle())
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .opacity(pressed && reduceMotion ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: pressed)
            .zIndex(-1)
    }
}

#Preview("Enabled") {
    LockboxLockNowButton {}
        .padding(.vertical, 32)
        .background(LockboxTheme.background)
}

#Preview("Disabled") {
    LockboxLockNowButton {}
        .disabled(true)
        .padding(.vertical, 32)
        .background(LockboxTheme.background)
}

#Preview("Accessibility size") {
    LockboxLockNowButton {}
        .environment(\.dynamicTypeSize, .accessibility3)
        .padding(.vertical, 32)
        .background(LockboxTheme.background)
}
