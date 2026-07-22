import XCTest
@testable import Hybridge

private final class FakeWidgetReloader: WidgetReloading {
    private(set) var reloadCount = 0
    func reloadAllTimelines() { reloadCount += 1 }
}

private final class FakeWidgetSnapshotStore: WidgetSnapshotStoring {
    private(set) var saved: [WidgetSnapshot] = []
    private var current: WidgetSnapshot?

    func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard snapshot != current else { return false }
        current = snapshot
        saved.append(snapshot)
        return true
    }
}

final class WidgetBridgeTests: XCTestCase {
    @MainActor
    func testStableFlushesProduceNoAdditionalWriteOrReload() {
        let reloader = FakeWidgetReloader()
        let store = FakeWidgetSnapshotStore()
        let snapshot = WidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 10), watchName: "Grant",
            hasDisplay: false, todaySteps: 100, stepsDate: Date(timeIntervalSince1970: 10),
            stepsAreLive: true, stepGoal: 10_000, batteryPercent: 80,
            batteryDate: Date(timeIntervalSince1970: 10), isConnected: true,
            lastSyncDate: Date(timeIntervalSince1970: 10))
        let bridge = WidgetBridge(reloader: reloader, snapshotStore: store) { snapshot }

        bridge.flushNow()
        bridge.flushNow()

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(reloader.reloadCount, 1)
    }

    @MainActor
    func testTimestampOnlyChangeWritesButDoesNotSpendReloadBudget() {
        let reloader = FakeWidgetReloader()
        let store = FakeWidgetSnapshotStore()
        var snapshot = WidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 10), watchName: "HR",
            hasDisplay: true, todaySteps: 100, stepsDate: Date(timeIntervalSince1970: 10),
            stepsAreLive: false, stepGoal: 10_000, batteryPercent: 80,
            batteryDate: Date(timeIntervalSince1970: 10), isConnected: true,
            lastSyncDate: nil)
        let bridge = WidgetBridge(reloader: reloader, snapshotStore: store) { snapshot }
        bridge.flushNow()
        snapshot.updatedAt = Date(timeIntervalSince1970: 11)
        snapshot.batteryDate = Date(timeIntervalSince1970: 11)
        bridge.flushNow()

        XCTAssertEqual(store.saved.count, 2)
        XCTAssertEqual(reloader.reloadCount, 1)
    }
}
