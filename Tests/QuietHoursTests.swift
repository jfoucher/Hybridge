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

private final class FakeBusyProvider: BusyIntervalProviding, @unchecked Sendable {
    var intervals: [BusyInterval] = []
    var accessGranted = true
    private(set) var requestAccessCallCount = 0
    private(set) var refreshCallCount = 0

    func busyIntervals(now: Date) -> [BusyInterval] { intervals }
    func refresh(now: Date) async { refreshCallCount += 1 }
    func requestAccessIfNeeded() async -> Bool {
        requestAccessCallCount += 1
        return accessGranted
    }
}

final class QuietHoursCalendarTests: XCTestCase {
    private static let suiteName = "QuietHoursCalendarTests"
    private var defaults: UserDefaults!
    private var busyProvider: FakeBusyProvider!
    private var manager: QuietHoursManager!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
        busyProvider = FakeBusyProvider()
        manager = QuietHoursManager(defaults: defaults, busyProvider: busyProvider)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    // A busy interval guaranteed to cover "now" regardless of when the test runs.
    private var alwaysBusy: [BusyInterval] {
        [BusyInterval(start: .distantPast, end: .distantFuture)]
    }

    // MARK: - status union (schedule left disabled by default, so only the
    // calendar leg is exercised deterministically — the schedule leg's own
    // math is covered by QuietHoursTests/QuietHoursManagerTests).

    func testStatusOffWhenCalendarDisabledEvenIfBusy() {
        busyProvider.intervals = alwaysBusy
        XCTAssertEqual(manager.status.source, .off)
        XCTAssertEqual(manager.status.mode, .day)
    }

    func testStatusCalendarBusyWhenEnabledAndBusy() {
        manager.calendarQuietEnabled = true
        busyProvider.intervals = alwaysBusy
        XCTAssertEqual(manager.status.source, .calendarBusy)
        XCTAssertEqual(manager.status.mode, .night)
    }

    func testStatusOffWhenCalendarEnabledButNotBusy() {
        manager.calendarQuietEnabled = true
        busyProvider.intervals = []
        XCTAssertEqual(manager.status.source, .off)
    }

    func testOverrideWinsOverCalendarBusy() async {
        manager.calendarQuietEnabled = true
        busyProvider.intervals = alwaysBusy
        await manager.setOverride(.day)
        XCTAssertEqual(manager.status.source, .override)
        XCTAssertEqual(manager.status.mode, .day)
    }

    // MARK: - nextBoundary union

    func testNextBoundaryIgnoresCalendarWhenDisabled() {
        let now = Date()
        busyProvider.intervals = [BusyInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60))]
        XCTAssertNil(manager.nextBoundary(now: now))   // schedule disabled, calendar ignored
    }

    func testNextBoundaryPicksEarlierCalendarBoundary() {
        let now = Date()
        manager.schedule = scheduleStarting(in: 180, endingIn: 240, from: now)
        manager.calendarQuietEnabled = true
        busyProvider.intervals = [BusyInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3600))]
        let boundary = manager.nextBoundary(now: now)
        XCTAssertNotNil(boundary)
        XCTAssertEqual(boundary!.timeIntervalSince(now), 3600, accuracy: 2)
    }

    func testNextBoundaryPicksEarlierScheduleBoundary() {
        let now = Date()
        manager.schedule = scheduleStarting(in: 30, endingIn: 90, from: now)
        manager.calendarQuietEnabled = true
        busyProvider.intervals = [BusyInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3600))]
        let boundary = manager.nextBoundary(now: now)
        XCTAssertNotNil(boundary)
        XCTAssertEqual(boundary!.timeIntervalSince(now), 30 * 60, accuracy: 2)
    }

    /// Builds a schedule using `Calendar.current` minute offsets from `now` —
    /// matching `QuietHours`' own default calendar, so the test is stable
    /// regardless of the machine's timezone.
    private func scheduleStarting(in startOffsetMinutes: Int, endingIn endOffsetMinutes: Int, from now: Date) -> QuietSchedule {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return QuietSchedule(enabled: true,
                              startMinutes: (nowMinutes + startOffsetMinutes) % 1440,
                              endMinutes: (nowMinutes + endOffsetMinutes) % 1440)
    }

    // MARK: - setCalendarQuietEnabled access gating

    func testSetCalendarQuietEnabledFalseNeverRequestsAccess() async {
        let ok = await manager.setCalendarQuietEnabled(false)
        XCTAssertTrue(ok)
        XCTAssertEqual(busyProvider.requestAccessCallCount, 0)
        XCTAssertFalse(manager.calendarQuietEnabled)
    }

    func testSetCalendarQuietEnabledTrueDeniedDoesNotPersist() async {
        busyProvider.accessGranted = false
        let ok = await manager.setCalendarQuietEnabled(true)
        XCTAssertFalse(ok)
        XCTAssertEqual(busyProvider.requestAccessCallCount, 1)
        XCTAssertFalse(manager.calendarQuietEnabled)
    }

    func testSetCalendarQuietEnabledTrueGrantedPersists() async {
        busyProvider.accessGranted = true
        let ok = await manager.setCalendarQuietEnabled(true)
        XCTAssertTrue(ok)
        XCTAssertTrue(manager.calendarQuietEnabled)
    }
}
