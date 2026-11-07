import SwiftUI

/// The shared round hero used by the Open screen (as the Lock now button) and
/// the Locked screen (as a non-interactive state display). Both render this
/// exact circle: same diameter, clamp and static halo. Only the fill colour and
/// content differ. `content` receives the circle's actual diameter.
struct LockboxStateCircle<Content: View>: View {
    let color: Color
    @ViewBuilder let content: (CGFloat) -> Content
    @ScaledMetric(relativeTo: .title) private var baseDiameter: CGFloat = 184

    var body: some View {
        Circle()
            .fill(color)
            .containerRelativeFrame(.horizontal) { width, _ in
                min(baseDiameter, width * 0.6)
            }
            .aspectRatio(1, contentMode: .fit)
            .background {
                Circle()
                    .fill(color.opacity(0.25))
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
                    content(proxy.size.width)
                        .foregroundStyle(LockboxTheme.onAccent)
                        .padding(.horizontal, proxy.size.width * 0.1)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity)
            .zIndex(-1) // keep the halo behind the header text
    }
}

/// The "Lock now" control on the Open screen. It locks on one tap until the
/// end shown on it. It never animates on its own; only touch-down feedback.
struct LockboxLockNowButton: View {
    /// Second line, e.g. "until 11:46 PM". Nil when no end is available.
    let endLine: String?
    /// Spoken end, e.g. "11:46 PM" or "tomorrow at 7:00 AM".
    let spokenEnd: String?
    /// Extra spoken context, e.g. that a saved bedtime extends the lock.
    var note: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            LockboxStateCircle(color: LockboxTheme.rest) { diameter in
                VStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: diameter * 0.22, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Lock now")
                        .font(.title3.weight(.semibold))
                    if let endLine {
                        Text(endLine)
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .opacity(0.75)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .buttonStyle(LockboxCircleButtonStyle())
        .accessibilityLabel(spokenEnd.map { "Lock now until \($0)" } ?? "Lock now")
        .accessibilityHint(isEnabled ? ["Locks right away.", note].compactMap { $0 }.joined(separator: " ") : "Needs Screen Time access or an available end")
        .saturation(isEnabled ? 1 : 0.3)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct LockboxCircleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .contentShape(Circle())
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .opacity(pressed && reduceMotion ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: pressed)
    }
}

#Preview("Enabled") {
    LockboxLockNowButton(endLine: "until 11:46 PM", spokenEnd: "11:46 PM") {}
        .padding(.vertical, 32)
        .background(LockboxTheme.background)
}

#Preview("Disabled") {
    LockboxLockNowButton(endLine: nil, spokenEnd: nil) {}
        .disabled(true)
        .padding(.vertical, 32)
        .background(LockboxTheme.background)
}

#Preview("Locked") {
    LockboxStateCircle(color: LockboxTheme.focus) { diameter in
        VStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: diameter * 0.16, weight: .semibold))
            Text("until").font(.subheadline)
            Text("Tomorrow").font(.subheadline.weight(.medium))
            Text("7:00 AM")
                .lockboxTimeHero()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
    .padding(.vertical, 32)
    .background(LockboxTheme.background)
}
