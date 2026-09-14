import SwiftUI

struct PeopleView: View {
    var body: some View {
        LockboxScrollView {
            LockboxPageHeader(title: "People")

            LockboxCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 12) {
                        LockboxIconBadge(systemImage: "person.2.fill", color: LockboxTheme.accent)
                        Text("A trusted person can help you recover")
                            .font(.title3.weight(.semibold))
                    }
                    Text("Phone Lockbox is designed for an honest, private recovery relationship—not a social feed or a remote control.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        LockboxSectionLabel("Current availability", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        LockboxStatusBadge(title: "Not connected", color: LockboxTheme.secondary)
                    }
                    LockboxValueRow(label: "Remote service", value: "Not connected")
                    Text("Remote approvals are unavailable until an authenticated, durable relay exists. No approval action is offered here yet.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 15) {
                    LockboxSectionLabel("How it is intended to work", systemImage: "sparkles")
                    ExplanationRow(icon: "iphone", title: "Same-app pairing", text: "Pairing will use mutually confirmed device-held identities. It will not require an email address or a hosted account.")
                    ExplanationRow(icon: "checkmark.shield", title: "Exact-lock intent", text: "A trusted person may eventually approve release of one exact current session. They will not start, extend, or take control of your restrictions.")
                    ExplanationRow(icon: "lock.privacy", title: "Private by design", text: "App selections and usage are not shared. Delayed recovery remains available on this device.")
                }
            }
        }
        .lockboxScreen()
    }
}

private struct ExplanationRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(LockboxTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack { PeopleView() }
}
