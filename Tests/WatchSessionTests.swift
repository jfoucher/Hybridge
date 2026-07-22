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
}
