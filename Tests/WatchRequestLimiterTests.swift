import XCTest
@testable import Hybridge

final class WatchRequestLimiterTests: XCTestCase {
    func testRateLimitResetsAtNextWindow() {
        let limiter = WatchRequestLimiter()
        XCTAssertTrue(limiter.acquire(.frame, limit: 2, per: 1, now: 10))
        XCTAssertTrue(limiter.acquire(.frame, limit: 2, per: 1, now: 10.5))
        XCTAssertFalse(limiter.acquire(.frame, limit: 2, per: 1, now: 10.9))
        XCTAssertTrue(limiter.acquire(.frame, limit: 2, per: 1, now: 11))
    }

    func testConcurrentCapRequiresRelease() {
        let limiter = WatchRequestLimiter()
        XCTAssertTrue(limiter.acquire(.homeAssistant, limit: 10, per: 60,
                                      maximumConcurrent: 1, now: 1))
        XCTAssertFalse(limiter.acquire(.homeAssistant, limit: 10, per: 60,
                                       maximumConcurrent: 1, now: 2))
        limiter.release(.homeAssistant)
        XCTAssertTrue(limiter.acquire(.homeAssistant, limit: 10, per: 60,
                                      maximumConcurrent: 1, now: 3))
    }
}
