import ActivityKit
import SwiftUI
import WidgetKit
import AmbientKit

@available(iOS 17.0, *)
struct LockboxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AmbientLiveActivityAttributes.self) { context in
            let display = AmbientLiveActivityPresentation(
                kind: context.attributes.kind,
                status: context.state.status,
                isStale: context.isStale
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: display.compactIconName)
                    Text(display.title)
                        .font(.headline)
                    if let demoIndicator = display.demoIndicator {
                        Text(demoIndicator)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Opens at \(context.state.fixedEnd.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                if let recoveryText = display.recoveryText {
                    Text(recoveryText)
                        .font(.caption)
                }
                if let staleActionText = display.staleActionText {
                    Text(staleActionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(display.accessibilityLabel) Opens at \(context.state.fixedEnd.formatted(date: .omitted, time: .shortened))."
            )
        } dynamicIsland: { context in
            let display = AmbientLiveActivityPresentation(
                kind: context.attributes.kind,
                status: context.state.status,
                isStale: context.isStale
            )
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: display.compactIconName)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 6) {
                        Text(display.title)
                        if let demoIndicator = display.demoIndicator {
                            Text(demoIndicator)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Opens at \(context.state.fixedEnd.formatted(date: .omitted, time: .shortened))")
                        if let recoveryText = display.recoveryText {
                            Text(recoveryText)
                        }
                        if let staleActionText = display.staleActionText {
                            Text(staleActionText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: display.compactIconName)
                    .accessibilityLabel(display.accessibilityLabel)
            } compactTrailing: {
                Text(context.state.fixedEnd, style: .time)
                    .accessibilityLabel(
                        "Opens at \(context.state.fixedEnd.formatted(date: .omitted, time: .shortened))"
                    )
            } minimal: {
                Image(systemName: display.compactIconName)
                    .accessibilityLabel(display.accessibilityLabel)
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
