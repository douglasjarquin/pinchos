import Foundation

/// Shared configuration for the single operation-level deadline that bounds
/// reload, removal, reorder rebuild, normal Quit, and signal-driven
/// shutdown. The deadline is computed once per operation (see
/// `StatusItemController`) and threaded through to every affected item and
/// runner instead of being restarted for each one, so total wait time is
/// bounded by the deadline plus small coordination overhead rather than by
/// the number of items or runners involved.
enum LifecycleDeadline {
    /// Matches `ShutdownCoordinator`'s cleanup timeout so the two bounds
    /// agree: this bounds how long a lifecycle operation waits for
    /// cooperative cancellation to settle, while `ShutdownCoordinator`
    /// remains the last-resort backstop that force-exits if cleanup as a
    /// whole (including this wait) overruns.
    static let defaultBudget: Duration = .seconds(5)

    static func makeInstant(
        budget: Duration = defaultBudget,
        clock: ContinuousClock = ContinuousClock()
    ) -> ContinuousClock.Instant {
        clock.now.advanced(by: budget)
    }
}

/// Identifies one runner/session that did not settle before a lifecycle
/// operation's shared deadline passed. Its cancellation request was already
/// sent and keeps running in the background -- this is purely a diagnostic
/// record for the deterministic failure policy described in issue #54: no
/// replacement/removal for the owning item may be committed while this
/// identity is still outstanding.
struct LifecycleSettlementTimeout: Equatable {
    let identity: String
}

/// Fires every provided cancellation operation concurrently and waits for
/// all of them to settle, bounded by one shared, monotonic `deadline` that
/// the caller computes once per lifecycle operation (see `LifecycleDeadline`)
/// and is never recomputed per item or per runner.
///
/// Every operation starts immediately, before this function does any
/// waiting, so slow settlement of one operation can never delay the start of
/// another. Operations still in flight when `deadline` passes are left
/// running to completion in the background: a runner that owns a live
/// process must be allowed to finish tearing it down so no old command
/// survives, so this function only bounds how long the *caller* waits, never
/// the cancellation work itself. Timed-out identities are reported through
/// `onTimeout` for diagnostics and caller-side commit policy.
@MainActor
func settleConcurrently(
    _ operations: [(identity: String, run: () async -> Void)],
    deadline: ContinuousClock.Instant,
    clock: ContinuousClock = ContinuousClock(),
    onTimeout: (([LifecycleSettlementTimeout]) -> Void)? = nil
) async {
    guard !operations.isEmpty else { return }
    let tracker = LifecycleSettlementTracker(identities: operations.map(\.identity))
    for operation in operations {
        Task { @MainActor in
            await operation.run()
            tracker.markSettled(operation.identity)
        }
    }
    let timedOut = await tracker.waitUntilSettledOrDeadline(deadline, clock: clock)
    if timedOut {
        onTimeout?(tracker.pendingIdentities().map(LifecycleSettlementTimeout.init))
    }
}

/// Serializes settlement bookkeeping on the main actor so the "all settled"
/// and "deadline passed" race resolves exactly once with no possibility of a
/// double resume, regardless of how many operations complete concurrently or
/// how close their completion lands to the deadline.
@MainActor
private final class LifecycleSettlementTracker {
    private var pending: Set<String>
    private var waiter: CheckedContinuation<Bool, Never>?
    private var resolved = false

    init(identities: [String]) {
        pending = Set(identities)
    }

    func pendingIdentities() -> [String] {
        Array(pending)
    }

    func markSettled(_ identity: String) {
        pending.remove(identity)
        guard pending.isEmpty else { return }
        resolve(timedOut: false)
    }

    /// Returns `true` if `deadline` passed before every identity settled.
    func waitUntilSettledOrDeadline(
        _ deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> Bool {
        if pending.isEmpty { return false }
        let now = clock.now
        guard now < deadline else {
            resolved = true
            return true
        }
        return await withCheckedContinuation { continuation in
            self.waiter = continuation
            Task { @MainActor in
                try? await clock.sleep(until: deadline)
                self.timeoutIfStillWaiting()
            }
        }
    }

    private func timeoutIfStillWaiting() {
        guard !resolved else { return }
        resolve(timedOut: true)
    }

    private func resolve(timedOut: Bool) {
        guard !resolved else { return }
        resolved = true
        waiter?.resume(returning: timedOut)
        waiter = nil
    }
}
