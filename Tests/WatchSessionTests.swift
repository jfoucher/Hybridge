import XCTest
@testable import Hybridge

/// The session mutex that keeps composed watch operations from interleaving.
/// The bug it exists to prevent — two operations each running their own
/// VerifyPrivateKey handshake, the second overwriting the first's session
/// randoms mid-transfer — cannot be reproduced without hardware, so these
/// tests pin the exclusion property itself.
final class WatchSessionTests: XCTestCase {

    /// Shared counter recording overlap between concurrent critical sections.
    private actor Overlap {
        private var active = 0
        private(set) var maxConcurrent = 0
        private(set) var completed = 0

        func enter() { active += 1; maxConcurrent = max(maxConcurrent, active) }
        func leave() { active -= 1; completed += 1 }
    }

    func testConcurrentOperationsNeverOverlap() async {
        let overlap = Overlap()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await WatchSession.exclusive {
                        await overlap.enter()
                        // Suspend inside the critical section: without a real
                        // mutex this is exactly where another task interleaves.
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        await overlap.leave()
                    }
                }
            }
        }

        let peak = await overlap.maxConcurrent
        let done = await overlap.completed
        XCTAssertEqual(peak, 1, "operations overlapped — the session is not exclusive")
        XCTAssertEqual(done, 20, "every waiter must eventually run (no lost wakeups)")
    }

    func testNestedAcquisitionDoesNotDeadlock() async {
        // Composed operations nest constantly (periodicMaintenance →
        // refreshBattery → readConfiguration → fetchConfiguration), so a
        // non-reentrant lock would deadlock on the first real sync.
        let reachedInner = expectation(description: "inner body ran")

        await WatchSession.exclusive {
            XCTAssertTrue(WatchSession.isHeld)
            await WatchSession.exclusive {
                await WatchSession.exclusive {
                    reachedInner.fulfill()
                }
            }
        }

        await fulfillment(of: [reachedInner], timeout: 1)
        XCTAssertFalse(WatchSession.isHeld, "the flag must not leak past the outermost body")
    }

    func testSessionIsReleasedAfterThrow() async {
        struct Boom: Error {}

        do {
            try await WatchSession.exclusive { throw Boom() }
            XCTFail("expected the error to propagate")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }

        // A leaked lock would hang here rather than fail.
        let ran = expectation(description: "session still usable")
        await WatchSession.exclusive { ran.fulfill() }
        await fulfillment(of: [ran], timeout: 1)
    }

    func testValueIsReturnedThrough() async throws {
        let value = try await WatchSession.exclusive { () -> Int in
            try await Task.sleep(nanoseconds: 100_000)
            return 42
        }
        XCTAssertEqual(value, 42)
    }

    func testNotHeldOutsideAnOperation() {
        XCTAssertFalse(WatchSession.isHeld)
    }

    private actor HoldsProbe {
        private(set) var snapshot: [String: (a: Bool, b: Bool)] = [:]
        func record(_ label: String, a: Bool, b: Bool) { snapshot[label] = (a, b) }
    }

    private func token(_ watchID: UUID) -> WatchConnectionToken {
        WatchConnectionToken(watchID: watchID, peripheralID: watchID,
                             generation: 1, kind: .hybridHR)
    }

    /// Two different watches must run their critical sections concurrently —
    /// the whole point of the per-watch gate. A single global mutex would
    /// serialize them and this peak would be 1.
    func testDifferentWatchesRunConcurrently() async {
        let a = token(UUID())
        let b = token(UUID())
        let overlap = Overlap()
        await withTaskGroup(of: Void.self) { group in
            for watchToken in [a, b] {
                group.addTask {
                    try? await WatchSession.exclusive(for: watchToken) {
                        await overlap.enter()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        await overlap.leave()
                    }
                }
            }
        }
        let peak = await overlap.maxConcurrent
        XCTAssertEqual(peak, 2, "distinct watches must not serialize against each other")
    }

    /// Contention on the *same* watch still serializes.
    func testSameWatchStillSerializes() async {
        let a = token(UUID())
        let overlap = Overlap()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try? await WatchSession.exclusive(for: a) {
                        await overlap.enter()
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        await overlap.leave()
                    }
                }
            }
        }
        let peak = await overlap.maxConcurrent
        let done = await overlap.completed
        XCTAssertEqual(peak, 1, "same-watch operations overlapped")
        XCTAssertEqual(done, 10)
    }

    /// Re-entering the same watch passes through; entering a second watch
    /// while holding the first acquires both gates (and `holds` reflects it).
    func testHoldsReflectsSameAndCrossWatchNesting() async throws {
        let a = token(UUID())
        let b = token(UUID())
        // Collected inside the closures and asserted afterwards, so the
        // XCTAssert autoclosures don't sit inside the exclusive() bodies (which
        // trips the type-checker's closure inference).
        let probe = HoldsProbe()
        try await WatchSession.exclusive(for: a) {
            await probe.record("a-outer", a: WatchSession.holds(a.watchID), b: WatchSession.holds(b.watchID))
            try await WatchSession.exclusive(for: a) {
                await probe.record("a-nested", a: WatchSession.holds(a.watchID), b: WatchSession.holds(b.watchID))
            }
            try await WatchSession.exclusive(for: b) {
                await probe.record("b-inner", a: WatchSession.holds(a.watchID), b: WatchSession.holds(b.watchID))
            }
            await probe.record("after-b", a: WatchSession.holds(a.watchID), b: WatchSession.holds(b.watchID))
        }
        let snapshot = await probe.snapshot
        XCTAssertEqual(snapshot["a-outer"]?.a, true)
        XCTAssertEqual(snapshot["a-outer"]?.b, false)
        XCTAssertEqual(snapshot["a-nested"]?.a, true, "same-watch nesting stays held")
        XCTAssertEqual(snapshot["b-inner"]?.a, true, "outer watch still held inside inner")
        XCTAssertEqual(snapshot["b-inner"]?.b, true, "inner watch acquired")
        XCTAssertEqual(snapshot["after-b"]?.b, false, "inner watch released after its body")
        XCTAssertFalse(WatchSession.holds(a.watchID))
        XCTAssertFalse(WatchSession.isHeld)
    }

    func testCancelledQueuedOperationNeverRuns() async {
        let firstEntered = expectation(description: "first operation owns the gate")
        let first = Task {
            try await WatchSession.exclusive(for: nil) {
                firstEntered.fulfill()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        await fulfillment(of: [firstEntered], timeout: 1)

        let bodyRan = expectation(description: "cancelled body must not run")
        bodyRan.isInverted = true
        let queued = Task {
            try await WatchSession.exclusive(for: nil) { bodyRan.fulfill() }
        }
        queued.cancel()
        do {
            try await queued.value
            XCTFail("cancelled waiter unexpectedly succeeded")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        try? await first.value
        await fulfillment(of: [bodyRan], timeout: 0.2)
    }
}
