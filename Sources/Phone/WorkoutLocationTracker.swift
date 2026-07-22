import Foundation
import CoreLocation
import UIKit
import UserNotifications

protocol LocationProviding: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var allowsBackgroundLocationUpdates: Bool { get set }
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

extension CLLocationManager: LocationProviding {}

/// GPS distance source for watch-initiated workouts (GB bridges to
/// OpenTracks; here CoreLocation feeds the watch directly). The watch polls
/// `req_distance` periodically and accumulates the *changes* we return
/// (GB: OpenTracksContentObserver resets its baseline on every poll).
///
/// Threading: the CoreLocation delegate callbacks arrive on main, but the
/// watch-driven control path (`pause`/`resume`/`isTracking`/`pollChange`,
/// reached from `handleWatchJsonRequest`) runs on `bleQueue`. All mutable
/// state is therefore guarded by `lock` — `lastLocation` in particular is a
/// reference whose unsynchronized cross-thread assignment is a retain/release
/// race, not merely a logic one. `manager` itself is only ever touched on
/// main, which is what `start()`/`stop()`'s dispatch guarantees.
final class WorkoutLocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = WorkoutLocationTracker()

    private let manager: any LocationProviding

    private let lock = NSLock()
    // All of the following are guarded by `lock`.
    private var lastLocation: CLLocation?
    private var totalDistanceMeters: Double = 0
    private var polledDistanceMeters: Double = 0
    private var lastPollDate = Date()
    private enum SessionState { case idle, requestingAuthorization, running, paused, stopping }
    private var sessionState: SessionState = .idle
    private var sessionToken: WatchConnectionToken?

    /// Main-thread mirrors for the UI (the Workout GPS demo screen). The
    /// authoritative state stays lock-guarded above; these are published from
    /// `start`/`stop`/the delegate on main.
    @Published private(set) var isRunning = false
    @Published private(set) var liveDistanceMeters: Double = 0

    private override convenience init() {
        self.init(locationProvider: CLLocationManager())
    }

    init(locationProvider: any LocationProviding) {
        manager = locationProvider
        super.init()
        if let manager = locationProvider as? CLLocationManager {
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.activityType = .fitness
            manager.distanceFilter = 5
            manager.showsBackgroundLocationIndicator = true
        }
        // Show the blue background-location indicator whenever GPS runs with
        // the app off screen. Transparency for the user, and the signal App
        // Review looks for when the `location` background mode is declared.
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func isTracking(for token: WatchConnectionToken?) -> Bool {
        withLock {
            (sessionState == .running || sessionState == .paused)
                && Self.sameSession(sessionToken, token)
        }
    }

    func start(for token: WatchConnectionToken? = nil) {
        let accepted = withLock { () -> Bool in
            guard sessionState == .idle else { return false }
            lastLocation = nil
            totalDistanceMeters = 0
            polledDistanceMeters = 0
            lastPollDate = Date()
            sessionToken = token
            sessionState = .requestingAuthorization
            return true
        }
        guard accepted else { return }
        DispatchQueue.main.async {
            let status = self.manager.authorizationStatus
            let backgrounded = UIApplication.shared.applicationState == .background

            // With when-in-use authorization, `allowsBackgroundLocationUpdates`
            // only *continues* a session started while the app was in the
            // foreground — it does not grant a new one, and a permission
            // prompt cannot be shown from the background either. This method is
            // reached from the watch's `workoutApp` event, so the common case
            // is exactly the one that cannot work: phone in a pocket, app
            // suspended. Rather than fail silently (distance stays 0, no error,
            // no log — the previous behaviour), tell the user.
            switch status {
            case .denied, .restricted:
                self.abortStart(status: status, backgrounded: backgrounded)
                return
            case .notDetermined where backgrounded:
                self.abortStart(status: status, backgrounded: backgrounded)
                return
            case .notDetermined:
                self.manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse where backgrounded:
                self.abortStart(status: status, backgrounded: backgrounded)
                return
            default:
                break   // authorizedAlways, or when-in-use with the app on screen
            }

            // Keeps GPS running once the phone locks (needs the `location`
            // background mode, which the app does declare).
            self.manager.allowsBackgroundLocationUpdates = true
            self.manager.startUpdatingLocation()
            self.withLock { self.sessionState = .running }
            self.isRunning = true
            self.liveDistanceMeters = 0
            WatchManager.shared.addLog("Workout GPS started")
        }
    }

    /// Starts a GPS session directly from the app (the Workout GPS demo
    /// screen), instead of from the watch's `workoutApp` event. Same session
    /// machinery — foreground-started, so it legitimately continues into the
    /// background — which lets the feature (and the `location` background mode)
    /// be exercised and shown to App Review without a paired watch.
    func startDemoWorkout() {
        WatchManager.shared.addLog("Workout GPS: demo session requested")
        start(for: nil)
    }

    func stopDemoWorkout() {
        stop()
    }

    /// Whether GPS is authorized enough to record (for the demo screen's UI).
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Rolls back the optimistic `tracking = true` and tells the user why.
    private func abortStart(status: CLAuthorizationStatus, backgrounded: Bool) {
        withLock {
            sessionState = .idle
            sessionToken = nil
        }
        isRunning = false   // on main (abortStart is only called from start()'s main dispatch)
        reportCannotTrack(status: status, backgrounded: backgrounded)
    }

    /// Tells the user why a watch-started workout won't record distance. A
    /// local notification is the only channel that reaches them here — by
    /// definition the app isn't on screen.
    private func reportCannotTrack(status: CLAuthorizationStatus, backgrounded: Bool) {
        let reason: String
        switch status {
        case .denied, .restricted:
            reason = String(localized: "Location access is off for Hybridge — turn it on in Settings to record distance.")
        case .notDetermined:
            reason = String(localized: "Open Hybridge and allow location access to record distance.")
        default:
            reason = String(localized: "Open Hybridge to record distance — iOS can't start GPS while the app is closed.")
        }
        WatchManager.shared.addLog("Workout GPS unavailable (status \(status.rawValue), "
                                   + "backgrounded \(backgrounded)) — user notified")
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Workout started")
        content.body = reason
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "workout.gpsUnavailable", content: content, trigger: nil))
    }

    func pause(for token: WatchConnectionToken? = nil) {
        withLock {
            guard sessionState == .running, Self.sameSession(sessionToken, token) else { return }
            sessionState = .paused
        }
    }

    func resume(for token: WatchConnectionToken? = nil) {
        withLock {
            guard sessionState == .paused, Self.sameSession(sessionToken, token) else { return }
            sessionState = .running
            lastLocation = nil   // don't count distance covered while paused
        }
    }

    func stop(for token: WatchConnectionToken? = nil) {
        let total: Double? = withLock {
            guard sessionState != .idle, sessionState != .stopping,
                  Self.sameSession(sessionToken, token) else { return nil }
            sessionState = .stopping
            return totalDistanceMeters
        }
        guard let total else {
            DispatchQueue.main.async { self.isRunning = false }
            return
        }
        DispatchQueue.main.async {
            self.manager.stopUpdatingLocation()
            self.manager.allowsBackgroundLocationUpdates = false
            self.withLock {
                self.sessionState = .idle
                self.sessionToken = nil
            }
            self.isRunning = false
            self.liveDistanceMeters = total
            WatchManager.shared.addLog(String(format: "Workout GPS stopped (%.0f m total)", total))
        }
    }

    /// Distance (cm) and time (s) since the previous poll — the semantics the
    /// watch expects for `workoutApp._.config.gps`.
    func pollChange(for token: WatchConnectionToken?) -> (distanceCm: Int, durationSecs: Int)? {
        withLock {
            guard Self.sameSession(sessionToken, token),
                  sessionState == .running || sessionState == .paused else { return nil }
            let now = Date()
            let distanceDelta = totalDistanceMeters - polledDistanceMeters
            let timeDelta = now.timeIntervalSince(lastPollDate)
            polledDistanceMeters = totalDistanceMeters
            lastPollDate = now
            let centimeters = min(max(distanceDelta * 100, 0), Double(Int.max))
            let seconds = min(max(timeDelta.rounded(), 0), Double(Int.max))
            return (Int(centimeters), Int(seconds))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let total: Double? = withLock {
            guard sessionState == .running else { return nil }
            for location in locations {
                let age = Date().timeIntervalSince(location.timestamp)
                guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 50,
                      age >= -5, age <= 30 else { continue }
                if let last = lastLocation {
                    guard location.timestamp > last.timestamp else { continue }
                    let elapsed = location.timestamp.timeIntervalSince(last.timestamp)
                    let distance = location.distance(from: last)
                    guard distance <= 200, elapsed > 0, distance / elapsed <= 15 else {
                        continue
                    }
                    totalDistanceMeters += distance
                }
                lastLocation = location
            }
            return totalDistanceMeters
        }
        // Publish for the demo screen. Delegate callbacks arrive on main.
        if let total { liveDistanceMeters = total }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        WatchManager.shared.addLog("Workout GPS error: \(error.localizedDescription)")
        withLock {
            sessionState = .idle
            sessionToken = nil
            lastLocation = nil
        }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
    }

    private static func sameSession(_ lhs: WatchConnectionToken?,
                                    _ rhs: WatchConnectionToken?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.authorizes(rhs)
        default: return false
        }
    }
}
