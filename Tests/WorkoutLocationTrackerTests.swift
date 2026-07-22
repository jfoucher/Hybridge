import XCTest
import CoreLocation
@testable import Hybridge

private final class FakeLocationProvider: LocationProviding {
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var allowsBackgroundLocationUpdates = false
    private(set) var requestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func requestWhenInUseAuthorization() { requestCount += 1 }
    func startUpdatingLocation() { startCount += 1 }
    func stopUpdatingLocation() { stopCount += 1 }
}

final class WorkoutLocationTrackerTests: XCTestCase {
    private func token(_ id: UUID, generation: UInt64 = 1) -> WatchConnectionToken {
        WatchConnectionToken(watchID: id, peripheralID: id,
                             generation: generation, kind: .hybridHR)
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    func testDuplicateStartAndForeignCommandsAreIgnored() async {
        let provider = FakeLocationProvider()
        let tracker = WorkoutLocationTracker(locationProvider: provider)
        let watchA = token(UUID())
        let watchB = token(UUID())

        tracker.start(for: watchA)
        tracker.start(for: watchA)
        await drainMainQueue()
        XCTAssertEqual(provider.startCount, 1)
        XCTAssertTrue(tracker.isTracking(for: watchA))
        XCTAssertFalse(tracker.isTracking(for: watchB))

        tracker.pause(for: watchB)
        XCTAssertTrue(tracker.isTracking(for: watchA))
        tracker.stop(for: watchB)
        await drainMainQueue()
        XCTAssertEqual(provider.stopCount, 0)

        tracker.stop(for: watchA)
        await drainMainQueue()
        XCTAssertEqual(provider.stopCount, 1)
        XCTAssertFalse(tracker.isTracking(for: watchA))
    }

    @MainActor
    func testImplausibleStaleAndOutOfOrderLocationsDoNotInflateDistance() async {
        let provider = FakeLocationProvider()
        let tracker = WorkoutLocationTracker(locationProvider: provider)
        let watch = token(UUID())
        tracker.start(for: watch)
        await drainMainQueue()

        let now = Date()
        let first = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 48.0, longitude: 2.0),
                               altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                               timestamp: now)
        let plausible = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 48.00008, longitude: 2.0),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            timestamp: now.addingTimeInterval(2))
        let hugeJump = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 49.0, longitude: 2.0),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            timestamp: now.addingTimeInterval(3))
        let stale = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 48.00016, longitude: 2.0),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            timestamp: now.addingTimeInterval(-60))
        tracker.locationManager(CLLocationManager(),
                                didUpdateLocations: [first, plausible, hugeJump, stale])

        let delta = tracker.pollChange(for: watch)
        XCTAssertNotNil(delta)
        XCTAssertGreaterThan(delta?.distanceCm ?? 0, 0)
        XCTAssertLessThan(delta?.distanceCm ?? .max, 2_000)
    }
}
