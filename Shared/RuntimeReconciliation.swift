import Foundation

public enum RuntimeReconciliationAction: Equatable, Sendable {
    case none
    case clearOwned
    case applyScheduled
    case applyPrototype
}

/// R1 crash recovery only, not the production occurrence/recovery engine.
/// A normal missed-end cleanup on foreground is a fallback, not evidence of
/// automatic release while the main app was closed.
public enum RuntimeReconciliation {
    public static func action(
        document: RuntimeStoreDocument,
        at date: Date,
        authorized: Bool,
        registrationMatches: Bool,
        calendar: Calendar = .current
    ) -> RuntimeReconciliationAction {
        guard !document.legacyRegistrationNeedsReview else { return .none }

        // A persisted intent is not tied to the callback that created it. Use
        // the current aggregate first: a manual-end callback must re-apply a
        // still-live scheduled session, while a terminal manual session must
        // replay the durable clear. This also covers an owner cleared after a
        // crash between the release commit and Managed Settings.
        if document.policyIntent != nil {
            let aggregate = RuntimeCallbackDecision.currentAggregate(document, at: date)
            if !aggregate.isEmpty {
                return authorized ? .applyScheduled : .none
            }
            if document.activeOwner == .prototypeTest,
               document.testLockActive,
               document.policyIntent == .apply {
                return authorized ? .applyPrototype : .none
            }
            return .clearOwned
        }

        guard let owner = document.activeOwner else { return .none }
        if owner == .scheduled {
            guard let configuration = document.configuration,
                  document.recurringEnabledIntent, registrationMatches,
                  RuntimeScheduleDecision.accepts(.start, configuration: configuration, at: date, calendar: calendar) else {
                return .clearOwned
            }
            return .none
        }
        return .none
    }
}
