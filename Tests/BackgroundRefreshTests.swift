import XCTest
@testable import Hybridge

final class BackgroundRefreshTests: XCTestCase {
    func testNeverSyncedIsDue() {
        XCTAssertTrue(BackgroundRefresher.syncIsDue(lastSync: nil, now: Date()))
    }

    func testRecentSyncIsNotDue() {
        let now = Date()
        let last = now.addingTimeInterval(-4 * 60)
        XCTAssertFalse(BackgroundRefresher.syncIsDue(lastSync: last, now: now))
    }

    func testStaleSyncIsDue() {
        let now = Date()
        let last = now.addingTimeInterval(-6 * 60)
        XCTAssertTrue(BackgroundRefresher.syncIsDue(lastSync: last, now: now))
    }

    func testCustomInterval() {
        let now = Date()
        let last = now.addingTimeInterval(-5 * 60)
        XCTAssertFalse(BackgroundRefresher.syncIsDue(lastSync: last, now: now, interval: 10 * 60))
        XCTAssertTrue(BackgroundRefresher.syncIsDue(lastSync: last, now: now, interval: 4 * 60))
    }
}
