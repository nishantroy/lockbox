import Foundation
import AmbientKit

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 17.0, *)
public final class LockboxLiveActivityAdapter: Sendable {
    public init() {}

    public func isAvailable() -> Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Best-effort only: no push token and no ActivityKit call is policy-critical.
    @MainActor
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
            // ActivityKit does not provide an idempotency key for request().
            // Reconcile an existing app-owned activity first so foreground
            // refreshes and relaunches never create duplicates for one session.
            let matches = matchingActivities(sessionID: sessionID)
            if let existing = matches.first {
                guard existing.attributes.fixedEnd == fixedEnd else { return .unavailable(.fixedEndMismatch) }
                await existing.update(.init(state: state, staleDate: fixedEnd))
                for duplicate in matches.dropFirst() {
                    let duplicateState = duplicate.content.state.staleIfNeeded(at: now)
                    await duplicate.end(.init(state: duplicateState, staleDate: duplicateState.fixedEnd), dismissalPolicy: .immediate)
                }
                return .updated
            }
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

    /// Reconciles an active committed session in the foreground. It starts
    /// only when no matching app-owned activity exists and never changes the
    /// fixed end stored in Activity attributes.
    @MainActor
    public func reconcile(
        sessionID: String,
        fixedEnd: Date,
        status: AmbientLiveActivityStatus,
        now: Date = .now
    ) async -> AmbientLiveActivityOutcome {
        await start(sessionID: sessionID, fixedEnd: fixedEnd, status: status, now: now)
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
    /// At/after the fixed end, the final state is explicitly stale. This route
    /// is retained for the explicit ambient/developer disable action only.
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

    /// Natural expiry is observed by the persisted runtime, but it is not an
    /// independently observed Managed Settings release. Keep that distinction
    /// in the final Activity state.
    public func endAfterObservedExpiry(
        sessionID: String
    ) async -> AmbientLiveActivityOutcome {
        guard let activity = matchingActivity(sessionID: sessionID) else {
            return .unavailable(.noMatchingActivity)
        }
        let fixedEnd = activity.attributes.fixedEnd
        let state = AmbientActivityContentState(fixedEnd: fixedEnd, status: .expired)
        await activity.end(.init(state: state, staleDate: fixedEnd), dismissalPolicy: .immediate)
        return .ended
    }

    /// Disabling the ambient preference ends only this app's activities. It is
    /// not called by enforcement cleanup and therefore cannot certify unlock.
    @MainActor
    public func endAllAppOwnedActivities(now: Date = .now) async -> Int {
        var ended = 0
        for activity in Activity<AmbientLiveActivityAttributes>.activities {
            let current = activity.content.state.staleIfNeeded(at: now)
            await activity.end(.init(state: current, staleDate: current.fixedEnd), dismissalPolicy: .immediate)
            ended += 1
        }
        return ended
    }

    private func matchingActivities(sessionID: String) -> [Activity<AmbientLiveActivityAttributes>] {
        Activity<AmbientLiveActivityAttributes>.activities.filter { $0.attributes.sessionID == sessionID }
    }

    private func matchingActivity(sessionID: String) -> Activity<AmbientLiveActivityAttributes>? {
        matchingActivities(sessionID: sessionID).first
    }
}
#endif
