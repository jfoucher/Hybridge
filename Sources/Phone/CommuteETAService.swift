import Foundation
import CoreLocation
import MapKit

/// Live commute ETAs: when the user picks a destination on the watch, this
/// looks up the route with MapKit and keeps the watch's commuteApp status
/// line updated every minute until the watch sends "stop" (the official
/// app's "My Commute"; GB relays to an external maps app instead).
/// `@MainActor`-isolated so the one-shot `locationContinuation` is only ever
/// touched on the main thread. It was previously read-resumed-reassigned from
/// a detached task while the CoreLocation delegate callbacks fired on main —
/// an unsynchronized race that could double-resume the CheckedContinuation
/// (a hard crash) and race the reference assignment. Same pattern WeatherProvider
/// uses; the delegate methods are `nonisolated` and hop back onto the actor.
@MainActor
final class CommuteETAService: NSObject, CLLocationManagerDelegate {
    static let shared = CommuteETAService()

    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var updateTask: Task<Void, Never>?

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Longest a commute loop may run. The commuteApp sends "stop" when the
    /// user dismisses it, but menu-triggered commutes have no stop signal —
    /// the loop must end itself (on arrival, or here at the latest).
    private static let maxDuration: TimeInterval = 3 * 60 * 60

    /// Handles a watch-side destination pick. Static reply when we know no
    /// coordinates; otherwise starts the repeating ETA push.
    func startCommute(to destinationName: String) {
        stop()
        guard let destination = CommuteStore.item(named: destinationName),
              destination.hasCoordinates else {
            Task {
                await WatchManager.shared.pushJsonWhenIdle(
                    JsonPayloads.commuteMessage(
                        String(localized: "On your way to \(destinationName)")))
            }
            return
        }
        let deadline = Date().addingTimeInterval(Self.maxDuration)
        updateTask = Task { [weak self] in
            while !Task.isCancelled, Date() < deadline {
                await self?.pushETA(to: destination)
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
    }

    private func pushETA(to destination: CommuteDestination) async {
        guard let latitude = destination.latitude, let longitude = destination.longitude else { return }
        guard let current = await currentLocation() else {
            await WatchManager.shared.pushJsonWhenIdle(
                JsonPayloads.commuteMessage(String(localized: "No location fix"), type: "in_progress"))
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: current.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        request.transportType = Self.transportType(destination.transport)

        do {
            let response = try await MKDirections(request: request).calculateETA()
            if response.expectedTravelTime < 60 {
                await WatchManager.shared.pushJsonWhenIdle(
                    JsonPayloads.commuteMessage(
                        String(localized: "Arrived at \(destination.name)"), type: "end"))
                WatchManager.shared.addLog("Commute to \(destination.name): arrived")
                stop()
                return
            }
            let minutes = Int((response.expectedTravelTime / 60).rounded())
            let arrival = Date().addingTimeInterval(response.expectedTravelTime)
            let arrivalText = arrival.formatted(date: .omitted, time: .shortened)
            let message = String(localized: "\(minutes) min · \(arrivalText)")
            await WatchManager.shared.pushJsonWhenIdle(JsonPayloads.commuteMessage(message))
            WatchManager.shared.addLog("Commute ETA to \(destination.name): \(message)")
        } catch {
            WatchManager.shared.addLog("Commute ETA failed: \(error.localizedDescription)")
            await WatchManager.shared.pushJsonWhenIdle(
                JsonPayloads.commuteMessage(
                    String(localized: "On your way to \(destination.name)")))
            stop()   // no point retrying a failing route every minute
        }
    }

    private static func transportType(_ raw: String) -> MKDirectionsTransportType {
        switch raw {
        case "walk": return .walking
        case "transit": return .transit
        default: return .automobile
        }
    }

    // MARK: One-shot location

    private func currentLocation() async -> CLLocation? {
        if let recent = locationManager.location,
           Date().timeIntervalSince(recent.timestamp) < 120 {
            return recent
        }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        return await withCheckedContinuation { continuation in
            locationContinuation?.resume(returning: nil)
            locationContinuation = continuation
            locationManager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.locationContinuation?.resume(returning: locations.last)
            self.locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.locationContinuation?.resume(returning: nil)
            self.locationContinuation = nil
        }
    }
}
