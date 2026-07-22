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
    @TaskLocal static var connectionToken: WatchConnectionToken?

    private static let gate = Gate()

    /// Runs `body` with exclusive ownership of the watch. Re-entrant: if the
    /// calling task already holds the session, `body` runs immediately.
    static func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        if isHeld { return try await body() }
        await gate.acquireUncancellable()
        do {
            let result = try await $isHeld.withValue(true) { try await body() }
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
    static func exclusive<T>(for token: WatchConnectionToken?,
                             _ body: () async throws -> T) async throws -> T {
        if isHeld { return try await body() }
        try Task.checkCancellation()
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await $isHeld.withValue(true) {
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
