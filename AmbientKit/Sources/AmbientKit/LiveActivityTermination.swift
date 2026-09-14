import Foundation

/// Selection rules for ending this app's Live Activities. These rules are
/// value-only so callback identity and the past-end fallback can be tested
/// without pretending to exercise ActivityKit.
public enum AmbientLiveActivityTermination {
    /// Callback-driven termination is bound to both immutable identity values.
    /// A reused route or a newer activity with a coincidentally equal end must
    /// never be selected by a stale callback.
    public static func matchesExactSession(
        activity: AmbientLiveActivityAttributes,
        sessionID: String,
        fixedEnd: Date,
        kind: AmbientLiveActivityKind? = nil
    ) -> Bool {
        activity.sessionID == sessionID &&
            activity.fixedEnd == fixedEnd &&
            (kind == nil || activity.kind == kind)
    }

    /// Foreground/relaunch cleanup is deliberately broader than callback
    /// cleanup because terminal history may have been pruned. It still only
    /// handles this app's real focus/bedtime activities and never a current or
    /// future activity. Demo activities remain under their explicit demo route.
    public static func shouldSweepPastFixedEnd(
        activity: AmbientLiveActivityAttributes,
        now: Date
    ) -> Bool {
        activity.kind != .demo && activity.fixedEnd <= now
    }
}

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

@available(iOS 17.0, *)
public enum AmbientLiveActivityTerminator {
    /// Ends every duplicate for one exact committed session. The caller must
    /// invoke this only after durable runtime state and policy replay have
    /// completed. ActivityKit remains presentation-only and best-effort.
    public static func endExactSession(
        sessionID: String,
        fixedEnd: Date,
        kind: AmbientLiveActivityKind? = nil,
        status: AmbientLiveActivityStatus
    ) async -> Int {
        let matches = Activity<AmbientLiveActivityAttributes>.activities.filter {
            AmbientLiveActivityTermination.matchesExactSession(
                activity: $0.attributes,
                sessionID: sessionID,
                fixedEnd: fixedEnd,
                kind: kind
            )
        }
        guard !matches.isEmpty else { return 0 }
        let state = AmbientActivityContentState(fixedEnd: fixedEnd, status: status)
        for activity in matches {
            await activity.end(
                .init(state: state, staleDate: fixedEnd),
                dismissalPolicy: .immediate
            )
        }
        return matches.count
    }

    /// Best-effort foreground/relaunch fallback. It uses stale presentation,
    /// not release-observed copy, because a past immutable end alone does not
    /// prove that Managed Settings released.
    public static func endPastFixedEndAppOwnedActivities(now: Date) async -> Int {
        let matches = Activity<AmbientLiveActivityAttributes>.activities.filter {
            AmbientLiveActivityTermination.shouldSweepPastFixedEnd(
                activity: $0.attributes,
                now: now
            )
        }
        for activity in matches {
            let state = AmbientActivityContentState(
                fixedEnd: activity.attributes.fixedEnd,
                status: .stale
            )
            await activity.end(
                .init(state: state, staleDate: activity.attributes.fixedEnd),
                dismissalPolicy: .immediate
            )
        }
        return matches.count
    }
}
#endif
