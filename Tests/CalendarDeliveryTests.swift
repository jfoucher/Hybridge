import XCTest
@testable import Hybridge

final class CalendarDeliveryTests: XCTestCase {
    func testFailureAndStaleTokenNeverAdvanceDeliveryHash() throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "CalendarDeliveryTests-\(UUID().uuidString)"))
        let watch = UUID()
        XCTAssertFalse(CalendarSync.commitDelivery(
            hash: 10, watchID: watch, sent: false, tokenStillValid: true,
            defaults: defaults))
        XCTAssertNil(defaults.object(forKey: CalendarSync.deliveryKey(for: watch)))
        XCTAssertNotNil(defaults.object(forKey: CalendarSync.failureKey(for: watch)))

        XCTAssertFalse(CalendarSync.commitDelivery(
            hash: 10, watchID: watch, sent: true, tokenStillValid: false,
            defaults: defaults))
        XCTAssertNil(defaults.object(forKey: CalendarSync.deliveryKey(for: watch)))
    }

    func testAcknowledgedDeliveryIsScopedByWatchAndSchema() throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "CalendarDeliveryTests-\(UUID().uuidString)"))
        let watchA = UUID()
        let watchB = UUID()
        XCTAssertTrue(CalendarSync.commitDelivery(
            hash: 42, watchID: watchA, sent: true, tokenStillValid: true,
            defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: CalendarSync.deliveryKey(for: watchA)) as? Int, 42)
        XCTAssertNil(defaults.object(forKey: CalendarSync.deliveryKey(for: watchB)))
        XCTAssertTrue(CalendarSync.deliveryKey(for: watchA)
            .contains(".v\(CalendarSync.payloadSchema)."))
    }
}
