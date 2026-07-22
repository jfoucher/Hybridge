import XCTest
@testable import Hybridge

final class WidgetSnapshotTests: XCTestCase {
    /// A fixed instant so date fields left at their defaults compare equal
    /// across separately-constructed snapshots within a single test.
    private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSnapshot(updatedAt: Date = WidgetSnapshotTests.referenceDate,
                              stepsDate: Date = WidgetSnapshotTests.referenceDate,
                              isConnected: Bool = true,
                              batteryPercent: Int? = 76,
                              batteryDate: Date? = WidgetSnapshotTests.referenceDate) -> WidgetSnapshot {
        WidgetSnapshot(updatedAt: updatedAt, watchName: "Test Watch", hasDisplay: true,
                       todaySteps: 4200, stepsDate: stepsDate, stepsAreLive: true,
                       stepGoal: 10000, batteryPercent: batteryPercent, batteryDate: batteryDate,
                       isConnected: isConnected, lastSyncDate: WidgetSnapshotTests.referenceDate)
    }

    // MARK: - Codec round-trip

    func testStoreRoundTrip() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        let snapshot = makeSnapshot()
        WidgetStore.save(snapshot, defaults: defaults)
        XCTAssertEqual(WidgetStore.load(defaults: defaults), snapshot)
    }

    func testLoadReturnsNilWhenNothingSaved() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        XCTAssertNil(WidgetStore.load(defaults: defaults))
    }

    func testLoadReturnsNilWhenDefaultsSuiteMissing() {
        XCTAssertNil(WidgetStore.load(defaults: nil))
    }

    func testLoadRejectsNewerVersion() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        var snapshot = makeSnapshot()
        snapshot.version = WidgetSnapshot.currentVersion + 1
        let data = try! JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: WidgetStore.snapshotKey)
        XCTAssertNil(WidgetStore.load(defaults: defaults))
    }

    // MARK: - stepsForDisplay: midnight rollover

    func testStepsForDisplaySameDay() {
        let now = Date()
        let snapshot = makeSnapshot(stepsDate: now)
        XCTAssertEqual(snapshot.stepsForDisplay(at: now.addingTimeInterval(60 * 30)), 4200)
    }

    func testStepsForDisplayNilAfterMidnightRollover() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: .now)!
        let snapshot = makeSnapshot(stepsDate: yesterday)
        XCTAssertNil(snapshot.stepsForDisplay(at: .now))
    }

    // MARK: - connectionForDisplay: 15-min validity

    func testConnectionForDisplayTrueWhenFresh() {
        let now = Date()
        let snapshot = makeSnapshot(updatedAt: now, isConnected: true)
        XCTAssertEqual(snapshot.connectionForDisplay(at: now.addingTimeInterval(60 * 5)), true)
    }

    func testConnectionForDisplayNilWhenStale() {
        let now = Date()
        let snapshot = makeSnapshot(updatedAt: now, isConnected: true)
        XCTAssertNil(snapshot.connectionForDisplay(at: now.addingTimeInterval(60 * 20)))
    }

    func testConnectionForDisplayFalseWhenDisconnectedEvenIfFresh() {
        let now = Date()
        let snapshot = makeSnapshot(updatedAt: now, isConnected: false)
        XCTAssertEqual(snapshot.connectionForDisplay(at: now), false)
    }

    // MARK: - batteryForDisplay: staleness thresholds

    func testBatteryForDisplayFreshNotStale() {
        let now = Date()
        let snapshot = makeSnapshot(batteryPercent: 50, batteryDate: now)
        let result = snapshot.batteryForDisplay(at: now.addingTimeInterval(60 * 30))
        XCTAssertEqual(result?.percent, 50)
        XCTAssertEqual(result?.isStale, false)
    }

    func testBatteryForDisplayStaleAfterOneHour() {
        let now = Date()
        let snapshot = makeSnapshot(batteryPercent: 50, batteryDate: now)
        let result = snapshot.batteryForDisplay(at: now.addingTimeInterval(60 * 90))
        XCTAssertEqual(result?.percent, 50)
        XCTAssertEqual(result?.isStale, true)
    }

    func testBatteryForDisplayHiddenAfter48Hours() {
        let now = Date()
        let snapshot = makeSnapshot(batteryPercent: 50, batteryDate: now)
        XCTAssertNil(snapshot.batteryForDisplay(at: now.addingTimeInterval(60 * 60 * 49)))
    }

    func testBatteryForDisplayNilWhenMissing() {
        let snapshot = makeSnapshot(batteryPercent: nil, batteryDate: nil)
        XCTAssertNil(snapshot.batteryForDisplay(at: .now))
    }

    // MARK: - rendersSameAs ignores timestamp churn

    func testRendersSameAsIgnoresUpdatedAtAndBatteryDate() {
        let base = makeSnapshot(updatedAt: Date(timeIntervalSince1970: 0),
                                batteryDate: Date(timeIntervalSince1970: 0))
        let laterButSameContent = makeSnapshot(updatedAt: .now, batteryDate: .now)
        XCTAssertTrue(base.rendersSameAs(laterButSameContent))
    }

    func testRendersSameAsFalseWhenStepsDiffer() {
        var base = makeSnapshot()
        var changed = base
        changed.todaySteps = base.todaySteps + 1
        XCTAssertFalse(base.rendersSameAs(changed))
        base.todaySteps = changed.todaySteps
        XCTAssertTrue(base.rendersSameAs(changed))
    }

    func testRendersSameAsFalseWhenConnectionDiffers() {
        let base = makeSnapshot(isConnected: true)
        let changed = makeSnapshot(isConnected: false)
        XCTAssertFalse(base.rendersSameAs(changed))
    }
}
