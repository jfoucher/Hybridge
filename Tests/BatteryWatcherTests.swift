import XCTest
@testable import Hybridge

final class BatteryWatcherTests: XCTestCase {
    private static let suiteName = "BatteryWatcherTests"
    private var defaults: UserDefaults!
    private var watcher: BatteryWatcher!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
        watcher = BatteryWatcher(defaults: defaults)
        watcher.isEnabled = true
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    // MARK: - evaluate (pure decision)

    func testWarnsAtOrBelowThreshold() {
        var result = BatteryWatcher.evaluate(level: 10, threshold: 15, alreadyWarned: false)
        XCTAssertTrue(result.warn)
        XCTAssertTrue(result.warnedFlag)

        // Exactly the threshold warns too.
        result = BatteryWatcher.evaluate(level: 15, threshold: 15, alreadyWarned: false)
        XCTAssertTrue(result.warn)
        XCTAssertTrue(result.warnedFlag)
    }

    func testDoesNotRewarnWhileFlagged() {
        let result = BatteryWatcher.evaluate(level: 9, threshold: 15, alreadyWarned: true)
        XCTAssertFalse(result.warn)
        XCTAssertTrue(result.warnedFlag)
    }

    func testDeadZoneChangesNothing() {
        // 16–19% at threshold 15: neither warns nor re-arms.
        for level in 16...19 {
            var result = BatteryWatcher.evaluate(level: level, threshold: 15, alreadyWarned: true)
            XCTAssertFalse(result.warn, "level \(level)")
            XCTAssertTrue(result.warnedFlag, "level \(level) must stay armed")

            result = BatteryWatcher.evaluate(level: level, threshold: 15, alreadyWarned: false)
            XCTAssertFalse(result.warn, "level \(level)")
            XCTAssertFalse(result.warnedFlag, "level \(level)")
        }
    }

    func testRearmsAtThresholdPlusMargin() {
        let result = BatteryWatcher.evaluate(level: 20, threshold: 15, alreadyWarned: true)
        XCTAssertFalse(result.warn)
        XCTAssertFalse(result.warnedFlag)
    }

    // MARK: - check (per-watch state)

    func testWarnsOncePerDischargeCycle() {
        let id = UUID()
        XCTAssertTrue(watcher.check(level: 10, watchID: id))
        XCTAssertFalse(watcher.check(level: 9, watchID: id))
        XCTAssertFalse(watcher.check(level: 16, watchID: id))  // dead-zone blip
        XCTAssertFalse(watcher.check(level: 9, watchID: id))   // still armed
        XCTAssertFalse(watcher.check(level: 20, watchID: id))  // recharged: re-arms
        XCTAssertTrue(watcher.check(level: 12, watchID: id))   // next cycle warns again
    }

    func testWatchesWarnIndependently() {
        let a = UUID(), b = UUID()
        XCTAssertTrue(watcher.check(level: 10, watchID: a))
        XCTAssertTrue(watcher.check(level: 10, watchID: b))    // b unaffected by a's flag
        XCTAssertFalse(watcher.check(level: 10, watchID: a))
        XCTAssertFalse(watcher.check(level: 10, watchID: b))

        // a recharges and drains again; b must stay armed throughout.
        watcher.check(level: 20, watchID: a)
        XCTAssertTrue(watcher.check(level: 10, watchID: a))
        XCTAssertFalse(watcher.check(level: 10, watchID: b))
    }

    func testDisabledStaysArmed() {
        let id = UUID()
        watcher.isEnabled = false
        XCTAssertFalse(watcher.check(level: 10, watchID: id))
        // Enabling on an already-low watch warns on the next reading.
        watcher.isEnabled = true
        XCTAssertTrue(watcher.check(level: 10, watchID: id))
    }

    func testDefaultThreshold() {
        XCTAssertEqual(watcher.threshold, 15)
        watcher.threshold = 30
        XCTAssertEqual(watcher.threshold, 30)
    }
}
