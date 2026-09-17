import Foundation

protocol QuickActionRouteQueue {
    func claimResult(now: Date) throws -> QuickActionPendingRouteStore.ClaimResult
    func acknowledge(_ claim: QuickActionPendingRouteStore.Claim) throws -> Bool
}

extension QuickActionPendingRouteStore: QuickActionRouteQueue {}

@MainActor
protocol QuickActionRetryScheduler: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, operation: @escaping () -> Void) -> UUID
    func cancel(_ identifier: UUID)
}

/// Main-thread scheduler used by the app. The broker still validates the
/// durable lease when this fires, so scheduler jitter or an early callback
/// cannot make a leased head available prematurely.
@MainActor
final class DispatchQuickActionRetryScheduler: QuickActionRetryScheduler {
    private var workItems: [UUID: DispatchWorkItem] = [:]

    @discardableResult
    func schedule(after delay: TimeInterval, operation: @escaping () -> Void) -> UUID {
        let identifier = UUID()
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            self?.workItems.removeValue(forKey: identifier)
            operation()
        }
        workItems[identifier] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
        return identifier
    }

    func cancel(_ identifier: UUID) {
        workItems.removeValue(forKey: identifier)?.cancel()
    }
}

enum QuickActionDeliveryDisposition: Equatable, Sendable {
    case present
    /// The route is navigation-only and cannot be presented in the current
    /// state. It must be acknowledged with its exact claim token so it cannot
    /// block later FIFO status/recovery routes.
    case dropNavigationOnly
}

/// Queue/broker boundary for navigation delivery. It owns no UI or policy
/// state: viable claims are handed to the coordinator, while expired,
/// malformed, and currently unpresentable routes are explicitly dropped by
/// token-bound acknowledgement. A claimed viable route receives a lease
/// deadline wake-up so a relaunch before expiry and an acknowledgement failure
/// both have a bounded retry path.
@MainActor
final class QuickActionDeliveryBroker {
    typealias Claim = QuickActionPendingRouteStore.Claim
    typealias Queue = any QuickActionRouteQueue

    private let queue: Queue?
    private let clock: () -> Date
    private let scheduler: QuickActionRetryScheduler
    private var retryIdentifier: UUID?
    private var retryDeadline: Date?
    private var retryGeneration = 0
    private var isBusy: (() -> Bool)?
    private var disposition: ((QuickActionRoute) -> QuickActionDeliveryDisposition)?
    private var present: ((Claim, QuickActionRoute) -> Bool)?
    private var terminal: ((Claim) -> Void)?

    init(
        queue: Queue?,
        clock: @escaping () -> Date = { Date() },
        scheduler: QuickActionRetryScheduler = DispatchQuickActionRetryScheduler()
    ) {
        self.queue = queue
        self.clock = clock
        self.scheduler = scheduler
    }

    /// Attempts one strict-FIFO delivery pass. The closures are retained only
    /// to re-enter the same pass from a lease timer; they should capture the
    /// coordinator weakly.
    func process(
        now: Date? = nil,
        isBusy: @escaping () -> Bool,
        disposition: @escaping (QuickActionRoute) -> QuickActionDeliveryDisposition,
        present: @escaping (Claim, QuickActionRoute) -> Bool,
        terminal: @escaping (Claim) -> Void = { _ in }
    ) {
        self.isBusy = isBusy
        self.disposition = disposition
        self.present = present
        self.terminal = terminal
        run(now: now ?? clock())
    }

    /// A destination settles only its captured claim. Failed acknowledgement
    /// is retryable at that claim's exact lease deadline; callers can then
    /// clear their in-memory UI identity without silently losing the durable
    /// route.
    func acknowledge(_ claim: Claim) -> Bool {
        guard let queue else {
            scheduleRetry(at: claim.leaseUntil)
            return false
        }
        do {
            let acknowledged = try queue.acknowledge(claim)
            if !acknowledged { scheduleRetry(at: claim.leaseUntil) }
            return acknowledged
        } catch {
            scheduleRetry(at: claim.leaseUntil)
            return false
        }
    }

    private func run(now: Date) {
        guard let queue,
              let isBusy,
              let disposition,
              let present else {
            cancelRetry()
            return
        }
        guard !isBusy() else { return }

        while true {
            let result: QuickActionPendingRouteStore.ClaimResult
            do {
                result = try queue.claimResult(now: now)
            } catch {
                // A corrupt/unavailable queue cannot safely be interpreted as
                // empty. Scene activation remains a separate retry trigger.
                return
            }

            switch result {
            case .empty:
                cancelRetry()
                return
            case .leased(let until):
                scheduleRetry(at: until)
                return
            case .claimed(let claim):
                guard let route = QuickActionRoute.parse(claim.url, now: now) else {
                    terminal?(claim)
                    if acknowledgeTerminal(claim) { continue }
                    return
                }
                switch disposition(route) {
                case .dropNavigationOnly:
                    terminal?(claim)
                    if acknowledgeTerminal(claim) { continue }
                    return
                case .present:
                    // Keep the timer while the UI identity is alive. A crash
                    // creates a new broker and can reclaim only at this exact
                    // deadline; a normal settlement cancels/replaces it.
                    scheduleRetry(at: claim.leaseUntil)
                    _ = present(claim, route)
                    return
                }
            }
        }
    }

    private func acknowledgeTerminal(_ claim: Claim) -> Bool {
        guard let queue else {
            scheduleRetry(at: claim.leaseUntil)
            return false
        }
        do {
            guard try queue.acknowledge(claim) else {
                scheduleRetry(at: claim.leaseUntil)
                return false
            }
            return true
        } catch {
            scheduleRetry(at: claim.leaseUntil)
            return false
        }
    }

    private func scheduleRetry(at deadline: Date) {
        guard retryDeadline != deadline else { return }
        cancelRetry()
        retryGeneration += 1
        let generation = retryGeneration
        let delay = max(0, deadline.timeIntervalSince(clock()))
        retryIdentifier = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.retryGeneration == generation else { return }
            self.retryIdentifier = nil
            self.retryDeadline = nil
            self.run(now: self.clock())
        }
        retryDeadline = deadline
    }

    private func cancelRetry() {
        retryGeneration += 1
        if let retryIdentifier {
            scheduler.cancel(retryIdentifier)
        }
        retryIdentifier = nil
        retryDeadline = nil
    }
}
