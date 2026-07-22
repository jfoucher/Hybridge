import XCTest
@testable import Hybridge

final class BackgroundRefreshTests: XCTestCase {
    private final class FakeTask: BackgroundTaskCompleting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var completions: [Bool] = []
        func setTaskCompleted(success: Bool) { lock.withLock { completions.append(success) } }
    }

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

    func testCompletionGuardCompletesExactlyOnceWhenPathsRace() async {
        let task = FakeTask()
        let guardObject = CompletionGuard(task: task)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { guardObject.complete(success: index.isMultiple(of: 2)) }
            }
        }
        XCTAssertEqual(task.completions.count, 1)
    }
}
