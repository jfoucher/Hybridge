import XCTest
import CoreLocation
import UIKit
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

    /// A watch-started workout that couldn't get GPS (permission not yet
    /// resolved, or the app was backgrounded) should retry automatically the
    /// next time the app comes to the foreground, rather than requiring the
    /// user to somehow know to retry manually.
    @MainActor
    func testAbortedStartRetriesOnForegroundWhenTokenStillValid() async {
        let provider = FakeLocationProvider()
        provider.authorizationStatus = .denied
        let tracker = WorkoutLocationTracker(locationProvider: provider, validatesToken: { _ in true })
        let watch = token(UUID())

        tracker.start(for: watch)
        await drainMainQueue()
        XCTAssertEqual(provider.startCount, 0)
        XCTAssertFalse(tracker.isTracking(for: watch))
        XCTAssertTrue(tracker.hasPendingRetry)

        // Permission gets fixed (e.g. via Settings) before the user reopens
        // the app.
        provider.authorizationStatus = .authorizedAlways
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await drainMainQueue()

        XCTAssertEqual(provider.startCount, 1)
        XCTAssertTrue(tracker.isTracking(for: watch))
        XCTAssertFalse(tracker.hasPendingRetry)
    }

    /// If the watch reconnected under a new BLE session while the app was
    /// backgrounded, the pending token no longer identifies a live
    /// connection — retrying with it would desync from the token the watch
    /// now sends with pause/resume/stop/poll requests, so it must be dropped
    /// instead of used to start a session.
    @MainActor
    func testAbortedStartDropsPendingRetryWhenTokenNoLongerValid() async {
        let provider = FakeLocationProvider()
        provider.authorizationStatus = .denied
        let tracker = WorkoutLocationTracker(locationProvider: provider, validatesToken: { _ in false })
        let watch = token(UUID())

        tracker.start(for: watch)
        await drainMainQueue()
        XCTAssertTrue(tracker.hasPendingRetry)

        provider.authorizationStatus = .authorizedAlways
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await drainMainQueue()

        XCTAssertEqual(provider.startCount, 0)
        XCTAssertFalse(tracker.isTracking(for: watch))
        XCTAssertFalse(tracker.hasPendingRetry)
    }

    /// If the watch reports the workout ended before the app ever made it to
    /// the foreground, the pending retry must be cancelled — otherwise the
    /// next foreground event would start tracking a workout that's already
    /// over.
    @MainActor
    func testStopBeforeForegroundCancelsPendingRetry() async {
        let provider = FakeLocationProvider()
        provider.authorizationStatus = .denied
        let tracker = WorkoutLocationTracker(locationProvider: provider, validatesToken: { _ in true })
        let watch = token(UUID())

        tracker.start(for: watch)
        await drainMainQueue()
        XCTAssertTrue(tracker.hasPendingRetry)

        tracker.stop(for: watch)
        await drainMainQueue()
        XCTAssertFalse(tracker.hasPendingRetry)

        provider.authorizationStatus = .authorizedAlways
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await drainMainQueue()
        XCTAssertEqual(provider.startCount, 0)
    }
}
