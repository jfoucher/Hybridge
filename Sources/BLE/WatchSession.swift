import Foundation

struct WatchConnectionToken: Equatable, Sendable {
    let watchID: UUID
    let peripheralID: UUID
    let generation: UInt64
    let kind: WatchKind

    /// Kind is learned after the firmware read. It is metadata, not part of
    /// the authority identity; a lease remains the same connection while its
    /// kind transitions from unknown to the detected family.
    func authorizes(_ other: WatchConnectionToken) -> Bool {
        watchID == other.watchID
            && peripheralID == other.peripheralID
            && generation == other.generation
    }
}

/// Mutual exclusion for *composed* watch operations.
///
/// `WatchConnection.run(_:)` serializes a single protocol request. That is not
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
/// **Per-watch.** With several watches connected at once, the exclusion must
/// be *per watch*: a config write to watch A must not block, or be blocked by,
/// one to watch B. Each watch has its own gate keyed by its UUID; a `nil` key
/// is the untokened gate used by the tests and the debug-only untokened
/// `exclusive`. Locking is always caller→callee (a top-level fan-out iterates
/// watches; a nested op re-enters the *same* watch), so the acquisition order
/// is acyclic and cannot deadlock.
///
/// Operations nest freely (`periodicMaintenance` → `refreshBattery` →
/// `readConfiguration` → `fetchConfiguration`), so acquisition is
/// **re-entrant per task, per watch**: the task-local `heldConnections` set
/// makes a nested `exclusive` on a watch already held a straight pass-through.
/// Task-locals propagate into `Task {}` children, which is what the request
/// paths use; `Task.detached` would not inherit and must not be used to nest
/// a watch operation.
enum WatchSession {
    /// The set of watch gates the current task already owns (a `nil` element
    /// is the untokened gate). Task-local, so it propagates into `Task {}`.
    @TaskLocal static var heldConnections: Set<UUID?> = []
    @TaskLocal static var connectionToken: WatchConnectionToken?

    /// True while the current task owns *any* session gate. Retained for the
    /// untokened test/debug API; production code paths use `holds(_:)` so the
    /// exclusion is checked against the specific watch being talked to.
    static var isHeld: Bool { !heldConnections.isEmpty }

    /// Whether the current task already owns `watchID`'s gate.
    static func holds(_ watchID: UUID?) -> Bool { heldConnections.contains(watchID) }

    private static let registry = GateRegistry()

    /// Runs `body` with exclusive ownership of the untokened gate. Re-entrant:
    /// if the calling task already holds it, `body` runs immediately. Used by
    /// the tests and by debug paths that have no connection token.
    static func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        if holds(nil) { return try await body() }
        let gate = registry.gate(for: nil)
        await gate.acquireUncancellable()
        do {
            let result = try await $heldConnections.withValue(heldConnections.union([nil])) {
                try await body()
            }
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Token-bound variant used by all production watch operations. The
    /// token is captured before waiting for the FIFO gate, so a task queued
    /// for watch A can never silently acquire the gate and run on watch B.
    /// Re-entrant per watch: a nested call on the same watch passes through;
    /// a nested call on a *different* watch acquires that watch's gate too.
    static func exclusive<T>(for token: WatchConnectionToken?,
                             _ body: () async throws -> T) async throws -> T {
        let key = token?.watchID
        if holds(key) { return try await body() }
        try Task.checkCancellation()
        let gate = registry.gate(for: key)
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await $heldConnections.withValue(heldConnections.union([key])) {
                try await $connectionToken.withValue(token) {
                    try await body()
                }
            }
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Vends one `Gate` per watch key, created lazily and race-free. Gates are
    /// never removed — there is one per registered watch at most, and a
    /// forgotten watch's gate is simply never acquired again.
    private final class GateRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [UUID?: Gate] = [:]

        func gate(for key: UUID?) -> Gate {
            lock.withLock {
                if let existing = gates[key] { return existing }
                let gate = Gate()
                gates[key] = gate
                return gate
            }
        }
    }

    /// FIFO async mutex. `release()` hands ownership *directly* to the next
    /// waiter (`busy` stays true across the handoff) instead of clearing
    /// `busy` and racing a fresh caller for it — so the queue is genuinely
    /// first-in-first-out and a newcomer can never barge ahead of a task that
    /// was already waiting.
    private actor Gate {
        private enum Continuation {
            case cancellable(CheckedContinuation<Void, Error>)
            case uncancellable(CheckedContinuation<Void, Never>)

            func resume() {
                switch self {
                case .cancellable(let continuation): continuation.resume()
                case .uncancellable(let continuation): continuation.resume()
                }
            }
        }

        private struct Waiter {
            let id: UUID
            let continuation: Continuation
        }
        private var busy = false
        private var waiters: [Waiter] = []

        func acquireUncancellable() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: UUID(), continuation: .uncancellable(continuation)))
            }
        }

        func acquire() async throws {
            try Task.checkCancellation()
            if !busy {
                busy = true
                return
            }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: id, continuation: .cancellable(continuation)))
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            let waiter = waiters.remove(at: index)
            guard case .cancellable(let continuation) = waiter.continuation else { return }
            continuation.resume(throwing: CancellationError())
        }

        func release() {
            if waiters.isEmpty {
                busy = false
            } else {
                // Keep `busy` true: the resumed waiter inherits the lock.
                waiters.removeFirst().continuation.resume()
            }
        }
    }
}
