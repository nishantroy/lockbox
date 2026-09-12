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
        guard let owner = document.activeOwner else { return .none }
        if document.policyIntent == .clear { return .clearOwned }
        guard !document.legacyRegistrationNeedsReview else { return .none }
        if owner == .scheduled {
            guard let configuration = document.configuration,
                  document.recurringEnabledIntent, registrationMatches,
                  RuntimeScheduleDecision.accepts(.start, configuration: configuration, at: date, calendar: calendar) else {
                return .clearOwned
            }
            return authorized && document.policyIntent == .apply ? .applyScheduled : .none
        }
        return authorized && document.policyIntent == .apply ? .applyPrototype : .none
    }
}
