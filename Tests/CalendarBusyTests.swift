import XCTest
@testable import Hybridge

final class CalendarBusyTests: XCTestCase {
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

    // MARK: - isBusy

    func testIsBusyInsideInterval() {
        let interval = BusyInterval(start: date(10, 0), end: date(11, 0))
        XCTAssertTrue(CalendarBusy.isBusy([interval], now: date(10, 30)))
    }

    func testIsBusyBoundaries() {
        let interval = BusyInterval(start: date(10, 0), end: date(11, 0))
        // Start inclusive, end exclusive — matches QuietHours.desiredMode.
        XCTAssertTrue(CalendarBusy.isBusy([interval], now: date(10, 0)))
        XCTAssertFalse(CalendarBusy.isBusy([interval], now: date(11, 0)))
    }

    func testIsBusyOutsideInterval() {
        let interval = BusyInterval(start: date(10, 0), end: date(11, 0))
        XCTAssertFalse(CalendarBusy.isBusy([interval], now: date(9, 0)))
        XCTAssertFalse(CalendarBusy.isBusy([interval], now: date(12, 0)))
    }

    func testIsBusyEmptyIntervals() {
        XCTAssertFalse(CalendarBusy.isBusy([], now: date(10, 0)))
    }

    func testIsBusyAnyOfSeveralIntervals() {
        let intervals = [
            BusyInterval(start: date(9, 0), end: date(9, 30)),
            BusyInterval(start: date(14, 0), end: date(15, 0)),
        ]
        XCTAssertTrue(CalendarBusy.isBusy(intervals, now: date(14, 30)))
        XCTAssertFalse(CalendarBusy.isBusy(intervals, now: date(10, 0)))
    }

    // MARK: - nextBoundary

    func testNextBoundaryWhileBusyIsIntervalEnd() {
        let interval = BusyInterval(start: date(10, 0), end: date(11, 0))
        XCTAssertEqual(CalendarBusy.nextBoundary([interval], now: date(10, 30)), date(11, 0))
    }

    func testNextBoundaryWhileFreeIsNearestFutureStart() {
        let intervals = [
            BusyInterval(start: date(14, 0), end: date(15, 0)),
            BusyInterval(start: date(9, 0), end: date(9, 30)),   // already past
        ]
        XCTAssertEqual(CalendarBusy.nextBoundary(intervals, now: date(10, 0)), date(14, 0))
    }

    func testNextBoundaryPicksSoonestOfMultipleBusyIntervals() {
        // Overlapping/back-to-back intervals: the soonest end wins.
        let intervals = [
            BusyInterval(start: date(10, 0), end: date(12, 0)),
            BusyInterval(start: date(10, 30), end: date(11, 0)),
        ]
        XCTAssertEqual(CalendarBusy.nextBoundary(intervals, now: date(10, 45)), date(11, 0))
    }

    func testNextBoundaryNoIntervalsIsNil() {
        XCTAssertNil(CalendarBusy.nextBoundary([], now: date(10, 0)))
    }

    func testNextBoundaryNoUpcomingIntervalsIsNil() {
        let interval = BusyInterval(start: date(9, 0), end: date(9, 30))
        XCTAssertNil(CalendarBusy.nextBoundary([interval], now: date(10, 0)))
    }
}
