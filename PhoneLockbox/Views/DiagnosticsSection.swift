import SwiftUI

struct DiagnosticsSection: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Registration", value: coordinator.registrationLabel)
                if let operation = coordinator.lastOperation.operation {
                    LabeledContent("Last operation", value: diagnosticLabel(operation))
                    if let observedAt = coordinator.lastOperation.observedAt {
                        LabeledContent("Observed", value: observedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let detail = coordinator.lastOperation.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(coordinator.lastOperation.succeeded == false ? LockboxTheme.destructive : LockboxTheme.secondary)
                            .textSelection(.enabled)
                    }
                }
                ForEach(Array(coordinator.recentDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Text(diagnosticLine(diagnostic))
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                }
                Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
                    .font(.caption)
                    .foregroundStyle(LockboxTheme.secondary)
            }
            .padding(.top, 8)
        } label: {
            Label("Operational status", systemImage: "stethoscope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LockboxTheme.primary)
        }
        .tint(LockboxTheme.accent)
    }

    private func diagnosticLine(_ diagnostic: RuntimeDiagnostic) -> String {
        let timestamp = diagnostic.observedAt.formatted(date: .abbreviated, time: .standard)
        return "\(timestamp): \(diagnosticLabel(diagnostic.operation))\n\(diagnostic.detail ?? "")"
    }

    // Keep these human-readable labels stable: they are also used in QA notes.
    private func diagnosticLabel(_ operation: RuntimeOperation) -> String {
        switch operation {
        case .configurationSaved: return "Configuration saved"
        case .registrationAttempted: return "Schedule registration requested"
        case .registrationSucceeded: return "Schedule registration accepted"
        case .registrationFailed: return "Schedule registration failed"
        case .callbackReceived: return "System callback received"
        case .policyApplyAttempted: return "Restriction update requested"
        case .policyApplied: return "Restriction update completed"
        case .policyApplyFailed: return "Restriction update failed"
        case .policyClearAttempted: return "Restriction cleanup requested"
        case .policyCleared: return "Restriction cleanup completed"
        case .policyClearFailed: return "Restriction cleanup failed"
        case .conflictRejected: return "Conflicting operation rejected"
        case .legacyMigration: return "Previous settings migrated"
        case .emergencyReset: return "Emergency reset completed"
        @unknown default: return "Other operation"
        }
    }
}
