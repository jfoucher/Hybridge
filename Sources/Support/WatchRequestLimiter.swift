import Foundation

/// Synchronous admission control at the BLE notification boundary. It runs
/// before creating an unstructured Task, so a malicious or broken watch app
/// cannot turn a packet flood into an unbounded task/network queue.
final class WatchRequestLimiter: @unchecked Sendable {
    static let shared = WatchRequestLimiter()
    static let maximumJSONBytes = 16 * 1024

    enum Kind: Hashable {
        case frame
        case homeAssistant
        case weather
    }

    private struct State {
        var windowStartedAt: TimeInterval = 0
        var acceptedInWindow = 0
        var active = 0
    }

    private let lock = NSLock()
    private var states: [Kind: State] = [:]

    /// Fixed-window admission plus an outstanding-work cap. `release` must be
    /// called for kinds whose `maximumConcurrent` is nonzero.
    func acquire(_ kind: Kind, limit: Int, per interval: TimeInterval,
                 maximumConcurrent: Int = 0,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var state = states[kind] ?? State(windowStartedAt: now)
        if now - state.windowStartedAt >= interval || now < state.windowStartedAt {
            state.windowStartedAt = now
            state.acceptedInWindow = 0
        }
        guard state.acceptedInWindow < limit,
              maximumConcurrent == 0 || state.active < maximumConcurrent else {
            states[kind] = state
            return false
        }
        state.acceptedInWindow += 1
        if maximumConcurrent > 0 { state.active += 1 }
        states[kind] = state
        return true
    }

    func release(_ kind: Kind) {
        lock.lock()
        var state = states[kind] ?? State()
        state.active = max(0, state.active - 1)
        states[kind] = state
        lock.unlock()
    }
}
