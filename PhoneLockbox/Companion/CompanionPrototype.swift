import SwiftUI
import Foundation

#if canImport(CompanionKit)
import Combine
import CompanionKit

/// Developer-only native adapter. It deliberately does not touch
/// ScreenTimeCoordinator, FamilyControls, ManagedSettings, or app selection.
@MainActor
public final class CompanionPrototypeModel: ObservableObject {
    @Published public private(set) var transcript = "Ready. This screen uses an in-memory simulated relay."

    public init() {}

    public func runSimulation() {
        do {
            let now = Date()
            let ownerKeys = InMemoryDeviceKeyStore()
            let approverKeys = InMemoryDeviceKeyStore()
            let ownerSigner = try DeviceSigner.create(role: .owner, keyStore: ownerKeys)
            let approverSigner = try DeviceSigner.create(role: .trustedApprover, keyStore: approverKeys)
            let relay = try InMemoryCompanionRelay(owner: ownerSigner.identity, now: now)
            let owner = CompanionClient(signer: ownerSigner, transport: relay, now: { now })
            let approver = CompanionClient(signer: approverSigner, transport: relay, now: { now })

            let issued = try owner.createInvite(inviteID: "developer-invite", validFor: 3_600, now: now,
                                                nonce: Data(repeating: 4, count: 24), ownerDisplayName: "Developer owner")
            let invitation = try approver.lookupInvite(token: issued.token)
            let pairing = try approver.acceptInvite(invitation, token: issued.token, approverDisplayName: "Developer friend",
                                                    acceptanceID: "developer-acceptance", now: now)
            let session = try ActiveSession(owner: ownerSigner.identity, sessionID: "developer-session",
                                            activeSetID: "developer-active-set", startsAt: now.addingTimeInterval(-1),
                                            endsAt: now.addingTimeInterval(3_600))
            _ = try owner.publishSession(session)
            let request = try owner.requestUnlock(requestID: "developer-request", pairing: pairing, session: session,
                                                  target: approverSigner.identity.identityID, message: nil,
                                                  validFor: 600)
            let approval = try approver.submitApproval(request: request, pairing: pairing, decision: .approved,
                                                       approvalID: "developer-approval")
            _ = try owner.useApproval(approval, request: request, useID: "developer-use")
            transcript = "Invite looked up and accepted in one step (consent active on both sides).\nRequest targeted one trusted identity.\nApproval verified once.\n\nSIMULATED RELAY ONLY — no remote unlock is connected."
        } catch {
            transcript = "Simulation failed: \(error)"
        }
    }
}

@MainActor
public struct CompanionPrototypeView: View {
    @StateObject private var model = CompanionPrototypeModel()

    public init() {}

    public var body: some View {
        Form {
            Section("Trusted-person companion") {
                Label("Accountless companion role", systemImage: "person.2")
                Text("The companion does not request Screen Time authorization, app selections, email, or phone numbers.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Developer harness") {
                Button("Run pairing → request → approval demo") { model.runSimulation() }
                Text(model.transcript).font(.footnote).textSelection(.enabled)
            }
            Section {
                Label("Simulated relay", systemImage: "network.slash")
                    .foregroundStyle(LockboxTheme.attention)
                Text("Foreground inbox fetch is the source of truth. APNs/wake delivery and remote unlock are not implemented in this prototype.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Companion prototype")
    }
}
#else
/// The parent app links CompanionKit separately. Keeping this fallback lets
/// the existing app continue to build before that package dependency is added.
public struct CompanionPrototypeView: View {
    public init() {}
    public var body: some View {
        Text("CompanionKit is not linked in this build.")
            .foregroundStyle(.secondary)
            .navigationTitle("Companion prototype")
    }
}
#endif
