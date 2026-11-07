import SwiftUI

/// Grouped settings rows (design language §2.3): rows on `surface`, separated
/// by hairline dividers, with no per-row card chrome.
struct LockboxRowGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LockboxTheme.surface, in: RoundedRectangle(cornerRadius: LockboxTheme.cornerRadius, style: .continuous))
    }
}

struct LockboxRowDivider: View {
    var body: some View {
        Divider().overlay(LockboxTheme.border.opacity(0.6))
    }
}

/// Label for a `NavigationLink` row: title, a trailing value, then a chevron.
/// Wrap in `NavigationLink { ... } label: { ... }` with `.buttonStyle(.plain)`.
struct LockboxNavigationRowLabel: View {
    let title: String
    var value: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LockboxTheme.primary)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(LockboxTheme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(LockboxTheme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// One line of help under a control or group.
struct LockboxHelpText: View {
    let text: String
    var color: Color = LockboxTheme.textSecondary

    init(_ text: String, color: Color = LockboxTheme.textSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A calm inline problem in the `attention` colour.
struct LockboxAttentionNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.subheadline)
            .foregroundStyle(LockboxTheme.attention)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Converts the coordinator's hour/minute components to a `Date` for a
/// `.hourAndMinute` picker, and back.
enum LockboxClockTime {
    static func date(from components: DateComponents) -> Date {
        Calendar.current.date(from: DateComponents(hour: components.hour ?? 0, minute: components.minute ?? 0)) ?? .now
    }

    static func components(from date: Date) -> DateComponents {
        Calendar.current.dateComponents([.hour, .minute], from: date)
    }

    static func runtimeTime(from components: DateComponents) -> RuntimeTime {
        RuntimeTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }
}
