import SwiftUI

/// A local preflight and review. It is intentionally presentation-only: no
/// action here changes a saved rule, starts recovery, or touches Screen Time.
struct SafetyAssistantView: View {
    @ObservedObject var coordinator: ScreenTimeCoordinator

    private var audit: SafetyAssistantAudit { coordinator.safetyAssistantAudit }

    var body: some View {
        LockboxScrollView {
            LockboxPageHeader(title: "Safety Assistant")

            LockboxCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Review essentials before stricter policies")
                        .font(.title3.weight(.semibold))
                    Text("This is a local checklist, not a guarantee. It does not change your policy, test emergency services, or send anything over the network.")
                        .font(.subheadline)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    LockboxSectionLabel("Current review context", systemImage: "checkmark.shield")
                    LockboxValueRow(label: "Mode", value: audit.mode.map(modeTitle) ?? "Not configured")
                    LockboxValueRow(label: "Selected items", value: "\(audit.opaqueSelectionCount) (opaque count)")
                    Text("The count is a summary only. No app names, tokens, identifiers, or usage are stored by this review.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    LockboxSectionLabel("Your essentials", systemImage: "list.clipboard")
                    Text("Mark each path you have considered for this device. Keep an alternate path available when something is essential.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    ForEach(SafetyAssistantChecklistItem.allCases) { item in
                        checklistRow(item)
                    }
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 13) {
                    LockboxSectionLabel("Warnings to review", systemImage: "exclamationmark.triangle")
                    ForEach(audit.findings) { finding in
                        findingRow(finding)
                    }
                }
            }

            LockboxCard {
                VStack(alignment: .leading, spacing: 12) {
                    LockboxSectionLabel("Bounded test checklist", systemImage: "checkmark.circle")
                    Text("Only run a short, disposable check you can stop. These checks never place calls and never prove emergency access or universal enforcement.")
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                    ForEach(SafetyAssistantTestStep.allCases) { step in
                        testStepRow(step)
                    }
                }
            }

            Text("Only these acknowledgements and this review version are saved locally. They never alter policy or block emergency recovery.")
                .font(.footnote)
                .foregroundStyle(LockboxTheme.secondary)
                .padding(.horizontal, 4)
        }
        .lockboxScreen()
        .navigationTitle("Safety Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func checklistRow(_ item: SafetyAssistantChecklistItem) -> some View {
        let acknowledged = coordinator.safetyAssistantAcknowledgements.checklist.contains(item)
        return Button {
            coordinator.setSafetyAssistantChecklistAcknowledged(item, acknowledged: !acknowledged)
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: acknowledged ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(acknowledged ? LockboxTheme.focus : LockboxTheme.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Text(item.prompt)
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(acknowledged ? "Reviewed" : "Needs review")
        .accessibilityHint("Marks this essential path as reviewed")
    }

    private func testStepRow(_ step: SafetyAssistantTestStep) -> some View {
        let acknowledged = coordinator.safetyAssistantAcknowledgements.testSteps.contains(step)
        return Button {
            coordinator.setSafetyAssistantTestStepAcknowledged(step, acknowledged: !acknowledged)
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: acknowledged ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(acknowledged ? LockboxTheme.focus : LockboxTheme.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                    Text(step.instructions)
                        .font(.footnote)
                        .foregroundStyle(LockboxTheme.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step.title)
        .accessibilityValue(acknowledged ? "Reviewed" : "Needs review")
        .accessibilityHint("Marks this bounded test as reviewed")
    }

    private func findingRow(_ finding: SafetyAssistantFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity == .action ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(finding.severity == .action ? .orange : LockboxTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.subheadline.weight(.semibold))
                Text(finding.detail)
                    .font(.footnote)
                    .foregroundStyle(LockboxTheme.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func modeTitle(_ mode: RuntimeMode) -> String {
        mode == .blockSelected ? "Block selected" : "Allow only selected"
    }
}
