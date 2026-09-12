import Foundation
import AmbientKit

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 17.0, *)
@MainActor
public final class LockboxLiveActivityAdapter {
    public init() {}

    public func isAvailable() -> Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Best-effort only: no push token and no ActivityKit call is policy-critical.
    public func start(
        sessionID: String,
        fixedEnd: Date,
        status: AmbientLiveActivityStatus = .plannedSession,
        now: Date = .now
    ) async -> AmbientLiveActivityOutcome {
        guard fixedEnd > now else { return .unavailable(.fixedEndPast) }
        if let rejection = AmbientLiveActivityPolicy.startRejection(status: status) {
            return .unavailable(rejection)
        }
        guard isAvailable() else { return .unavailable(.userDisabled) }

        let attributes = AmbientLiveActivityAttributes(sessionID: sessionID, fixedEnd: fixedEnd)
        let state = AmbientActivityContentState(fixedEnd: fixedEnd, status: status)
        do {
            _ = try Activity<AmbientLiveActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: state, staleDate: fixedEnd),
                pushType: nil
            )
            return .started(lifetime: AmbientLiveActivityPolicy.lifetime(for: fixedEnd, now: now))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func update(
        sessionID: String,
        fixedEnd: Date,
        status: AmbientLiveActivityStatus,
        now: Date = .now
    ) async -> AmbientLiveActivityOutcome {
        guard let activity = matchingActivity(sessionID: sessionID) else {
            return .unavailable(.noMatchingActivity)
        }
        if let rejection = AmbientLiveActivityPolicy.updateRejection(
            attributes: activity.attributes,
            requestedFixedEnd: fixedEnd,
            status: status
        ) {
            return .unavailable(rejection)
        }
        let requested = AmbientActivityContentState(
            fixedEnd: activity.attributes.fixedEnd,
            status: status
        )
        let state = requested.staleIfNeeded(at: now)
        await activity.update(.init(state: state, staleDate: activity.attributes.fixedEnd))
        return .updated
    }

    /// Ending without an observed Managed Settings update never claims release.
    /// At/after the fixed end, the final state is explicitly stale.
    public func end(sessionID: String, now: Date = .now) async -> AmbientLiveActivityOutcome {
        guard let activity = matchingActivity(sessionID: sessionID) else {
            return .unavailable(.noMatchingActivity)
        }
        let current = activity.content.state.staleIfNeeded(at: now)
        await activity.end(.init(state: current, staleDate: current.fixedEnd), dismissalPolicy: .immediate)
        return .ended
    }

    /// This API is intentionally named for the only condition that permits
    /// release copy. The caller must supply an observed session update.
    public func endAfterObservedRelease(
        sessionID: String
    ) async -> AmbientLiveActivityOutcome {
        guard let activity = matchingActivity(sessionID: sessionID) else {
            return .unavailable(.noMatchingActivity)
        }
        let fixedEnd = activity.attributes.fixedEnd
        let state = AmbientActivityContentState(fixedEnd: fixedEnd, status: .releaseObserved)
        await activity.end(.init(state: state, staleDate: fixedEnd), dismissalPolicy: .immediate)
        return .ended
    }

    private func matchingActivity(sessionID: String) -> Activity<AmbientLiveActivityAttributes>? {
        Activity<AmbientLiveActivityAttributes>.activities.first { $0.attributes.sessionID == sessionID }
    }
}
#endif
