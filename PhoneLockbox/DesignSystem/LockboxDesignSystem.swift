import SwiftUI

/// Midnight Original is intentionally small: one deep canvas, navy surfaces,
/// lavender rest/actions, and cool blue focus semantics.
enum LockboxTheme {
    static let background = Color(red: 0.035, green: 0.047, blue: 0.11)
    static let surface = Color(red: 0.075, green: 0.095, blue: 0.19)
    static let surfaceRaised = Color(red: 0.105, green: 0.125, blue: 0.24)
    static let surfaceMuted = Color(red: 0.055, green: 0.068, blue: 0.145)
    static let primary = Color(red: 0.95, green: 0.94, blue: 1.0)
    static let secondary = Color(red: 0.68, green: 0.70, blue: 0.82)
    static let accent = Color(red: 0.76, green: 0.69, blue: 0.98)
    static let rest = Color(red: 0.76, green: 0.69, blue: 0.98)
    static let focus = Color(red: 0.46, green: 0.76, blue: 0.98)
    static let border = Color(red: 0.25, green: 0.28, blue: 0.45)
    static let onAccent = Color(red: 0.08, green: 0.055, blue: 0.16)
    static let attention = Color(red: 0.961, green: 0.714, blue: 0.380) // #F5B661
    static let destructive = Color.red
    /// Help text and section labels (design language §3).
    static let textSecondary = secondary

    static let cornerRadius: CGFloat = 20
    static let controlCornerRadius: CGFloat = 12
}

struct LockboxScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(LockboxTheme.background.ignoresSafeArea())
        .foregroundStyle(LockboxTheme.primary)
    }
}

struct LockboxPageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.weight(.semibold))
            .foregroundStyle(LockboxTheme.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

struct LockboxCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LockboxTheme.surface, in: RoundedRectangle(cornerRadius: LockboxTheme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LockboxTheme.cornerRadius, style: .continuous)
                    .stroke(LockboxTheme.border.opacity(0.75), lineWidth: 1)
            }
    }
}

struct LockboxSectionLabel: View {
    let title: String
    let systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(LockboxTheme.textSecondary)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Time hero: rounded, large, semibold, fixed-width digits. Wraps rather
    /// than truncating at large Dynamic Type sizes.
    func lockboxTimeHero() -> some View {
        self
            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Short, calm time strings: "10:00 PM", "Tomorrow 7:00 AM", "Sat 7:00 AM".
enum LockboxTimeFormat {
    static func string(_ date: Date, now: Date = Date(), calendar: Calendar = .current, inSentence: Bool = false) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "\(inSentence ? "tomorrow" : "Tomorrow") \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
}

struct LockboxValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(LockboxTheme.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(LockboxTheme.primary)
        }
    }
}

struct LockboxStatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.9)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct LockboxIconBadge: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.title2.weight(.semibold))
            .foregroundStyle(LockboxTheme.onAccent)
            .frame(width: 48, height: 48)
            .background(color, in: Circle())
            .accessibilityHidden(true)
    }
}

extension View {
    func lockboxScreen() -> some View {
        self
            .background(LockboxTheme.background.ignoresSafeArea())
            .foregroundStyle(LockboxTheme.primary)
            .tint(LockboxTheme.accent)
            .toolbarBackground(LockboxTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(LockboxTheme.background, for: .tabBar)
            .preferredColorScheme(.dark)
    }
}
