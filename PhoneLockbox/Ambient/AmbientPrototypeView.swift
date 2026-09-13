import SwiftUI
import AmbientKit

#if canImport(ActivityKit)
@available(iOS 17.0, *)
public struct AmbientPrototypeView: View {
    @State private var windDownEnabled = false
    @State private var bedtimeHour = 22
    @State private var bedtimeMinute = 0
    @State private var leadMinutes = 30
    @State private var message = "Checking pending prototype reminders…"
    @State private var isScheduling = false
    @State private var demoActive = false
    @State private var demoEnd: Date?

    private let notifications = WindDownNotificationScheduler()
    private let liveActivity = LockboxLiveActivityAdapter()

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Enable heads-up (draft)", isOn: $windDownEnabled)
                Stepper("Bedtime \(String(format: "%02d:%02d", bedtimeHour, bedtimeMinute))", value: $bedtimeHour, in: 0...23)
                    .accessibilityLabel("Bedtime hour")
                Stepper("Bedtime minutes \(String(format: "%02d", bedtimeMinute))", value: $bedtimeMinute, in: 0...59, step: 5)
                    .accessibilityLabel("Bedtime minutes")
                Stepper("Lead time \(leadMinutes) minutes", value: $leadMinutes, in: 1...1_440)
            } header: {
                Text("Wind-down prototype")
            } footer: {
                Text("Standalone reminder demo, not linked to saved bedtime rules. Scheduled reminders remain until delivered or disabled.")
            }

            Button("Request notification permission") {
                Task {
                    do {
                        let result = try await notifications.requestAuthorization()
                        message = "Notification authorization: \(result)."
                    } catch {
                        message = "Notification permission error: \(error.localizedDescription)"
                    }
                }
            }

            .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))

            Button(windDownEnabled ? "Schedule wind-down" : "Disable wind-down") {
                Task {
                    guard !isScheduling else { return }
                    isScheduling = true
                    defer { isScheduling = false }
                    await applyWindDown()
                }
            }
            .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
            .disabled(isScheduling)

            Section {
                Text("Live Activity demo")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("This screen is a demo outside the lock and notification status.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(demoActive ? "Demo presentation active until \(demoEnd?.formatted(date: .omitted, time: .shortened) ?? "unknown")." : "Demo presentation inactive.")
                Button("Start demo") {
                    Task { await startDemo() }
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .primary))
                Button("Update demo: recovery requested") {
                    Task { await updateDemo() }
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .secondary))
                Button("End demo") {
                    Task { await endDemo() }
                }
                .buttonStyle(LockboxActionButtonStyle(emphasis: .destructive))
            } footer: {
                Text("Live Activities are best-effort presentation. They do not unlock or enforce restrictions.")
            }

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Ambient prototypes")
        .task {
            let count = await notifications.pendingOwnedRequestCount()
            if let existingEnd = liveActivity.existingFixedEnd(sessionID: "ambient-demo") {
                demoActive = true
                demoEnd = existingEnd
                message = "Live Activity demo is active. \(count) prototype reminder(s) pending."
            } else {
                demoActive = false
                demoEnd = nil
                message = "\(count) prototype reminder(s) currently pending. Use Disable wind-down to remove them."
            }
        }
    }

    private func makeConfiguration() throws -> WindDownConfiguration {
        WindDownConfiguration(
            enabled: windDownEnabled,
            bedtime: try AmbientLocalTime(hour: bedtimeHour, minute: bedtimeMinute),
            lead: try WindDownLeadOffset(minutes: leadMinutes)
        )
    }

    @MainActor
    private func applyWindDown() async {
        do {
            let configuration = try makeConfiguration()
            let occurrences = try WindDownPlanner.plan(
                configuration: configuration,
                now: .now,
                calendar: .autoupdatingCurrent
            )
            if configuration.enabled {
                let result = try await notifications.replace(
                    occurrences: occurrences
                )
                switch result {
                case .replaced(let count):
                    message = "Scheduled \(count) local wind-down heads-up(s)."
                case .failed(let requestedCount, let addedCount, let previousScheduleRestored):
                    if previousScheduleRestored {
                        message = "Wind-down unchanged: adding request \(addedCount + 1) of \(requestedCount) failed; the previous schedule was restored."
                    } else {
                        message = "Wind-down partially changed: \(addedCount) of \(requestedCount) request(s) were added; open Phone Lockbox to reconcile."
                    }
                }
            } else {
                await notifications.disable()
                message = "Wind-down disabled; owned notifications removed."
            }
        } catch {
            message = "Wind-down not changed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func startDemo() async {
        let end = liveActivity.existingFixedEnd(sessionID: "ambient-demo")
            ?? Date(timeIntervalSinceNow: 2 * 60 * 60)
        let result = await liveActivity.start(
            sessionID: "ambient-demo",
            fixedEnd: end,
            kind: .demo
        )
        switch result {
        case .started(let lifetime):
            demoActive = true
            demoEnd = end
            message = "Live Activity demo started (\(lifetime)); no lock was changed."
        default:
            message = "Live Activity demo unavailable: \(String(describing: result))"
        }
    }

    @MainActor
    private func updateDemo() async {
        guard let demoEnd else {
            message = "Start the demo first."
            return
        }
        let result = await liveActivity.update(
            sessionID: "ambient-demo",
            fixedEnd: demoEnd,
            status: .recoveryPending
        )
        message = "Live Activity update: \(String(describing: result))."
    }

    @MainActor
    private func endDemo() async {
        let result = await liveActivity.end(sessionID: "ambient-demo")
        demoActive = false
        message = "Live Activity demo ended: \(String(describing: result))."
    }
}
#endif
