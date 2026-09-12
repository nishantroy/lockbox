import ActivityKit
import SwiftUI
import WidgetKit
import AmbientKit

@available(iOS 17.0, *)
struct LockboxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AmbientLiveActivityAttributes.self) { context in
            let display = AmbientLiveActivityPresentation(
                status: context.state.status,
                isStale: context.isStale
            )
            VStack(alignment: .leading, spacing: 6) {
                Text("Phone Lockbox")
                    .font(.headline)
                Text(display.title)
                    .font(.subheadline)
                Text("Fixed end: \(context.state.fixedEnd.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                Text(display.accessibilityLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Phone Lockbox. \(display.accessibilityLabel). Fixed end \(context.state.fixedEnd.formatted(date: .omitted, time: .shortened))")
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Lockbox")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(AmbientLiveActivityPresentation(
                        status: context.state.status,
                        isStale: context.isStale
                    ).title)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(AmbientLiveActivityPresentation(
                            status: context.state.status,
                            isStale: context.isStale
                        ).accessibilityLabel)
                            .font(.caption2)
                        Text("Fixed end: \(context.state.fixedEnd.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                    }
                }
            } compactLeading: {
                Text("LB")
                    .accessibilityLabel(
                        context.isStale
                            ? "Phone Lockbox. \(AmbientLiveActivityPresentation(status: context.state.status, isStale: true).accessibilityLabel)"
                            : "Phone Lockbox"
                    )
            } compactTrailing: {
                Text(AmbientLiveActivityPresentation(
                    status: context.state.status,
                    isStale: context.isStale
                ).compactLabel)
                    .font(.caption2)
                    .accessibilityLabel(AmbientLiveActivityPresentation(
                        status: context.state.status,
                        isStale: context.isStale
                    ).accessibilityLabel)
            } minimal: {
                Text(AmbientLiveActivityPresentation(
                    status: context.state.status,
                    isStale: context.isStale
                ).compactLabel)
                    .accessibilityLabel(AmbientLiveActivityPresentation(
                        status: context.state.status,
                        isStale: context.isStale
                    ).accessibilityLabel)
            }
        }
    }
}

@main
@available(iOS 17.0, *)
struct LockboxLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LockboxLiveActivity()
    }
}
