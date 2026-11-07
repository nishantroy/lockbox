import SwiftUI

/// Grouped rows (design language §2.3): one `surface` container with hairline
/// dividers between rows, instead of a card per row. Rows supply their own
/// 16 pt padding so a row can fill its whole width.
struct LockboxGroupedRows<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LockboxTheme.surface, in: RoundedRectangle(cornerRadius: LockboxTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LockboxTheme.cornerRadius, style: .continuous)
                .stroke(LockboxTheme.border.opacity(0.6), lineWidth: 1)
        }
    }
}

/// Grouped rows over a collection, with hairline dividers between rows and
/// 16 pt padding around each row.
struct LockboxGroupedList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        LockboxGroupedRows {
            ForEach(items) { item in
                row(item)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.id != items.last?.id { LockboxRowDivider() }
            }
        }
    }
}

struct LockboxRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(LockboxTheme.border.opacity(0.6))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
