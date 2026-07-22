import XCTest
@testable import Hybridge

final class QuietHoursTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ hour: Int, _ minute: Int, day: Int = 15) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    // MARK: - desiredMode

    func testDesiredModeNormalWindow() {
        let schedule = QuietSchedule(enabled: true, startMinutes: 13 * 60, endMinutes: 14 * 60)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(13, 30), calendar: calendar), .night)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(12, 0), calendar: calendar), .day)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(15, 0), calendar: calendar), .day)
    }

    func testDesiredModeOvernightWrap() {
        let schedule = QuietSchedule(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(23, 0), calendar: calendar), .night)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(3, 0), calendar: calendar), .night)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(12, 0), calendar: calendar), .day)
    }

    func testDesiredModeBoundaryMinutes() {
        let schedule = QuietSchedule(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        // Start is inclusive (>=), end is exclusive (<).
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(22, 0), calendar: calendar), .night)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(21, 59), calendar: calendar), .day)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(7, 0), calendar: calendar), .day)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(6, 59), calendar: calendar), .night)
    }

    func testDesiredModeDisabledScheduleIsAlwaysDay() {
        let schedule = QuietSchedule(enabled: false, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(23, 0), calendar: calendar), .day)
    }

    func testDesiredModeDegenerateWindowIsAlwaysDay() {
        let schedule = QuietSchedule(enabled: true, startMinutes: 9 * 60, endMinutes: 9 * 60)
        XCTAssertEqual(QuietHours.desiredMode(schedule: schedule, now: date(9, 0), calendar: calendar), .day)
    }

    // MARK: - nextBoundary

    func testNextBoundaryAcrossMidnight() {
        let schedule = QuietSchedule(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)

        // Currently day (before the window): next boundary is tonight's start.
        let fromNoon = QuietHours.nextBoundary(schedule: schedule, now: date(12, 0), calendar: calendar)
        XCTAssertEqual(fromNoon, date(22, 0))

        // Currently night, after midnight: next boundary is this morning's end.
        let fromEarlyMorning = QuietHours.nextBoundary(schedule: schedule, now: date(3, 0), calendar: calendar)
        XCTAssertEqual(fromEarlyMorning, date(7, 0))

        // Currently night, before midnight: next boundary rolls to tomorrow's end.
        let fromLateEvening = QuietHours.nextBoundary(schedule: schedule, now: date(23, 0), calendar: calendar)
        XCTAssertEqual(fromLateEvening, date(7, 0, day: 16))
    }

    func testNextBoundaryDisabledOrDegenerateIsNil() {
        XCTAssertNil(QuietHours.nextBoundary(
            schedule: QuietSchedule(enabled: false, startMinutes: 22 * 60, endMinutes: 7 * 60),
            now: date(12, 0), calendar: calendar))
        XCTAssertNil(QuietHours.nextBoundary(
            schedule: QuietSchedule(enabled: true, startMinutes: 9 * 60, endMinutes: 9 * 60),
            now: date(12, 0), calendar: calendar))
    }
}

final class QuietHoursManagerTests: XCTestCase {
    private static let suiteName = "QuietHoursManagerTests"
    private var defaults: UserDefaults!
    private var manager: QuietHoursManager!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
        manager = QuietHoursManager(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    func testScheduleRoundTrips() {
        XCTAssertFalse(manager.schedule.enabled)   // default
        manager.schedule = QuietSchedule(enabled: true, startMinutes: 60, endMinutes: 120)
        XCTAssertEqual(manager.schedule, QuietSchedule(enabled: true, startMinutes: 60, endMinutes: 120))
    }

    // Mirrors QuietOverride's private Codable shape to plant fixtures
    // directly in UserDefaults without touching WatchManager via evaluate().
    private struct ProbeOverride: Codable { var mode: String; var expiry: Date? }

    func testExpiredOverrideIsIgnored() throws {
        let stale = ProbeOverride(mode: "night", expiry: Date().addingTimeInterval(-60))
        defaults.set(try JSONEncoder().encode(stale), forKey: WatchScopedKey.quietOverride.rawValue)
        XCTAssertNil(manager.overrideMode)
        XCTAssertEqual(manager.effectiveMode, .day)   // falls back to the (disabled) schedule
    }

    func testFutureExpiryOverrideStillApplies() throws {
        let future = ProbeOverride(mode: "night", expiry: Date().addingTimeInterval(3600))
        defaults.set(try JSONEncoder().encode(future), forKey: WatchScopedKey.quietOverride.rawValue)
        XCTAssertEqual(manager.overrideMode, .night)
        XCTAssertEqual(manager.effectiveMode, .night)
    }

    func testNoExpiryOverridePersistsIndefinitely() throws {
        let noExpiry = ProbeOverride(mode: "day", expiry: nil)
        defaults.set(try JSONEncoder().encode(noExpiry), forKey: WatchScopedKey.quietOverride.rawValue)
        XCTAssertEqual(manager.overrideMode, .day)
    }
}
