import SwiftUI

struct PeopleView: View {
    var body: some View {
        Form {
            Section {
                Label("A trusted person can help you recover", systemImage: "person.2.fill")
                    .font(.headline)
                Text("Phone Lockbox is designed for an honest, private recovery relationship—not a social feed or a remote control.")
                    .foregroundStyle(.secondary)
            }

            Section("Current availability") {
                LabeledContent("Remote service", value: "Not connected")
                Text("Remote approvals are unavailable until an authenticated, durable relay exists. No approval action is offered here yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("How it is intended to work") {
                Label("Same-app pairing", systemImage: "iphone")
                Text("Pairing will use mutually confirmed device-held identities. It will not require an email address or a hosted account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label("Exact-lock intent", systemImage: "checkmark.shield")
                Text("A trusted person may eventually approve release of one exact current session. They will not start, extend, or take control of your restrictions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label("Private by design", systemImage: "lock.privacy")
                Text("App selections and usage are not shared. Delayed recovery remains available on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("People")
    }
}

#Preview {
    NavigationStack { PeopleView() }
}
