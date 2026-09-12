import ActivityKit
import SwiftUI
import WidgetKit
import AmbientKit

@available(iOS 17.0, *)
struct LockboxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AmbientLiveActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text("Phone Lockbox")
                    .font(.headline)
                Text(statusTitle(context.state.status))
                    .font(.subheadline)
                Text("Fixed end: \(context.state.fixedEnd.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                Text(context.state.status.accessibilityLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Phone Lockbox. \(context.state.status.accessibilityLabel). Fixed end \(context.state.fixedEnd.formatted(date: .omitted, time: .shortened))")
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Lockbox")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(statusTitle(context.state.status))
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Fixed end: \(context.state.fixedEnd.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                }
            } compactLeading: {
                Text("LB")
                    .accessibilityLabel("Phone Lockbox")
            } compactTrailing: {
                Text(context.state.status == .recoveryPending ? "REC" : "PLAN")
                    .font(.caption2)
                    .accessibilityLabel(context.state.status.accessibilityLabel)
            } minimal: {
                Text("LB")
                    .accessibilityLabel("Phone Lockbox planned session")
            }
        }
    }
}

private func statusTitle(_ status: AmbientLiveActivityStatus) -> String {
    switch status {
    case .plannedSession: return "Planned session"
    case .recoveryPending: return "Recovery requested"
    case .releaseObserved: return "Release observed"
    case .expired: return "Session end reached"
    case .stale: return "Status stale"
    }
}

@main
@available(iOS 17.0, *)
struct LockboxLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LockboxLiveActivity()
    }
}
