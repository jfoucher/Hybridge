import Foundation

/// Mutual exclusion for *composed* watch operations.
///
/// `WatchManager.run(_:)` serializes a single protocol request. That is not
/// enough: almost every operation in WatchActions/QWatchActions is a
/// *sequence* of requests that must not interleave with another sequence.
/// The sharpest example is the encrypted write path.
/// A fresh VerifyPrivateKey handshake is required before every encrypted put,
/// and the session randoms it produces seed the AES-CTR IV. If two operations
/// interleave, the second handshake overwrites the first's randoms and the
/// first encrypts its payload under the wrong IV. On the notification-filter
/// file that risks writing a config the watch reads as empty, which drops
/// every notification until the user re-pushes.
///
/// There are five independent trigger sources (the foreground maintenance
/// timer, will-enter-foreground, the BGAppRefreshTask, four App Intents, and
/// direct UI taps), so this is reachable in normal use, not just in theory.
///
/// Operations nest freely (`periodicMaintenance` → `refreshBattery` →
/// `readConfiguration` → `fetchConfiguration`), so acquisition is
/// **re-entrant per task**: the task-local `isHeld` flag makes a nested
/// `exclusive` a straight pass-through. Task-locals propagate into `Task {}`
/// children, which is what the request paths use; `Task.detached` would not
/// inherit and must not be used to nest a watch operation.
enum WatchSession {
    /// True while the current task already owns the session.
    @TaskLocal static var isHeld = false

    private static let gate = Gate()

    /// Runs `body` with exclusive ownership of the watch. Re-entrant: if the
    /// calling task already holds the session, `body` runs immediately.
    static func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        if isHeld { return try await body() }
        await gate.acquire()
        do {
            let result = try await $isHeld.withValue(true) { try await body() }
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    /// FIFO async mutex. `release()` hands ownership *directly* to the next
    /// waiter (`busy` stays true across the handoff) instead of clearing
    /// `busy` and racing a fresh caller for it — so the queue is genuinely
    /// first-in-first-out and a newcomer can never barge ahead of a task that
    /// was already waiting.
    private actor Gate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !busy {
                busy = true
                return
            }
            // Parked until a release() resumes us; ownership is already ours
            // at that point (busy was never cleared), so we don't re-check.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }

        func release() {
            if waiters.isEmpty {
                busy = false
            } else {
                // Keep `busy` true: the resumed waiter inherits the lock.
                waiters.removeFirst().resume()
            }
        }
    }
}
