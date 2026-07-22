import Foundation
import CoreLocation
import WeatherKit
import UIKit

/// Weather push for the watch's `weatherApp`, `weatherInfo` watchface widget,
/// and the rain/UV widgets (GB: FossilHRWatchAdapter.java:1507-1660, 2011-2035).
///
/// Validated on real hardware. Location uses when-in-use authorization only:
/// a fresh fix is taken while foregrounded and cached, so background watch
/// requests never need Always. Requires the WeatherKit entitlement
/// (`com.apple.developer.weatherkit`).
@MainActor
final class WeatherProvider: NSObject, ObservableObject {
    static let shared = WeatherProvider()

    private static let enabledKey = "weatherPushEnabled"
    private static let lastLatKey = "weatherLastLat"
    private static let lastLonKey = "weatherLastLon"
    private static let lastCityKey = "weatherLastCity"
    private static let cacheTTL: TimeInterval = 15 * 60

    @Published var lastPushDate: Date?
    @Published private(set) var lastCity: String?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private let locationManager = CLLocationManager()
    private var pendingLocation: (id: UUID, continuation: CheckedContinuation<CLLocation?, Never>)?
    private var locationTask: Task<CLLocation?, Never>?
    private var cachedSnapshot: WeatherSnapshot?
    private var cachedAt: Date?

    private var useMetric: Bool { (UserDefaults.standard.object(forKey: "useMetric") as? Bool) ?? true }

    override init() {
        super.init()
        locationManager.delegate = self
        lastCity = UserDefaults.standard.string(forKey: Self.lastCityKey)
    }

    // MARK: - Triggered by watch JSON requests

    /// `weatherInfo` or `weatherApp._.config.locations` was asked for — GB
    /// sends both payloads regardless of which key triggered the request.
    func respondFullWeather(requestId: Int, token: WatchConnectionToken? = nil) async {
        let target = token ?? WatchManager.shared.connectionTokenSync()
        guard let target, WatchManager.shared.validatesConnectionToken(target),
              isEnabled, let snapshot = await snapshot() else { return }
        await WatchManager.shared.pushJsonWhenIdle(
            JsonPayloads.weatherInfoResponse(id: requestId, snapshot: snapshot), expectedToken: target)
        await WatchManager.shared.pushJsonWhenIdle(
            JsonPayloads.weatherAppResponse(id: requestId, snapshot: snapshot), expectedToken: target)
        lastPushDate = Date()
    }

    func respondRainWidget(token: WatchConnectionToken? = nil) async {
        let target = token ?? WatchManager.shared.connectionTokenSync()
        guard let target, WatchManager.shared.validatesConnectionToken(target),
              isEnabled, let snapshot = await snapshot() else { return }
        await WatchManager.shared.pushJsonWhenIdle(
            JsonPayloads.rainWidgetResponse(rainPercent: snapshot.rain), expectedToken: target)
        lastPushDate = Date()
    }

    func respondUVWidget(token: WatchConnectionToken? = nil) async {
        let target = token ?? WatchManager.shared.connectionTokenSync()
        guard let target, WatchManager.shared.validatesConnectionToken(target),
              isEnabled, let snapshot = await snapshot() else { return }
        await WatchManager.shared.pushJsonWhenIdle(
            JsonPayloads.uvWidgetResponse(uv: snapshot.uv), expectedToken: target)
        lastPushDate = Date()
    }

    /// Proactive push right after connect, so complications populate without
    /// the watch having to ask first.
    func pushIfEnabled() async {
        guard let target = WatchManager.shared.connectionTokenSync(),
              WatchManager.shared.validatesConnectionToken(target),
              isEnabled, let snapshot = await snapshot() else { return }
        await WatchManager.shared.pushJsonWhenIdle(
            JsonPayloads.weatherInfoResponse(id: 0, snapshot: snapshot), expectedToken: target)
        await WatchManager.shared.pushJsonWhenIdle(
            JsonPayloads.weatherAppResponse(id: 0, snapshot: snapshot), expectedToken: target)
        lastPushDate = Date()
    }

    // MARK: - Fetch + cache

    private func snapshot() async -> WeatherSnapshot? {
        if let cachedSnapshot, let cachedAt, Date().timeIntervalSince(cachedAt) < Self.cacheTTL {
            return cachedSnapshot
        }
        guard let location = await currentLocation() else {
            WatchManager.shared.addLog("Weather: no location available yet")
            return nil
        }
        do {
            let (current, hourly, daily) = try await WeatherService.shared.weather(
                for: location, including: .current, .hourly, .daily)
            let city = await reverseGeocodeCity(location) ?? lastCity ?? ""
            let snapshot = Self.makeSnapshot(current: current, hourly: hourly, daily: daily,
                                             city: city, useMetric: useMetric)
            cachedSnapshot = snapshot
            cachedAt = Date()
            lastCity = city
            UserDefaults.standard.set(city, forKey: Self.lastCityKey)
            return snapshot
        } catch {
            WatchManager.shared.addLog("WeatherKit fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func reverseGeocodeCity(_ location: CLLocation) async -> String? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return placemark.locality ?? placemark.name
    }

    // MARK: - Location

    private func currentLocation() async -> CLLocation? {
        if UIApplication.shared.applicationState == .active, let fresh = await requestOneShotLocation() {
            UserDefaults.standard.set(fresh.coordinate.latitude, forKey: Self.lastLatKey)
            UserDefaults.standard.set(fresh.coordinate.longitude, forKey: Self.lastLonKey)
            return fresh
        }
        guard let lat = UserDefaults.standard.object(forKey: Self.lastLatKey) as? Double,
              let lon = UserDefaults.standard.object(forKey: Self.lastLonKey) as? Double else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
    }

    private func requestOneShotLocation() async -> CLLocation? {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            return nil     // prompt is async; this pass falls back to the cache
        case .authorizedWhenInUse, .authorizedAlways:
            if let locationTask { return await locationTask.value }
            let task = Task { await performOneShotLocation() }
            locationTask = task
            let result = await task.value
            locationTask = nil
            return result
        default:
            return nil
        }
    }

    private func performOneShotLocation() async -> CLLocation? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingLocation = (id, continuation)
                locationManager.requestLocation()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    self?.finishLocation(id: id, result: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishLocation(id: id, result: nil)
            }
        }
    }

    private func finishLocation(id: UUID, result: CLLocation?) {
        guard let pendingLocation, pendingLocation.id == id else { return }
        self.pendingLocation = nil
        pendingLocation.continuation.resume(returning: result)
    }

    // MARK: - Snapshot assembly

    /// WeatherKit `WeatherCondition` -> GB icon table (FossilHRWatchAdapter.java:1457-1505).
    /// `nonisolated` + pure so it's directly unit-testable without a MainActor context.
    nonisolated static func condId(for condition: WeatherCondition, isDaylight: Bool) -> Int {
        switch condition {
        case .clear, .mostlyClear:
            return isDaylight ? 0 : 1
        case .partlyCloudy, .mostlyCloudy:
            return isDaylight ? 3 : 4
        case .cloudy, .foggy, .haze, .smoky, .blowingDust:
            return 2
        case .drizzle, .rain, .sleet, .hail, .freezingRain, .freezingDrizzle, .heavyRain, .sunShowers:
            return 5
        case .snow, .flurries, .blizzard, .blowingSnow, .heavySnow, .sunFlurries, .wintryMix:
            return 6
        case .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms:
            return 8
        case .windy, .breezy, .hurricane, .tropicalStorm:
            return 10
        default:
            return 2
        }
    }

    nonisolated private static func message(for condId: Int) -> String {
        switch condId {
        case 0, 1: return String(localized: "Clear")
        case 2: return String(localized: "Cloudy")
        case 3, 4: return String(localized: "Partly Cloudy")
        case 5: return String(localized: "Rain")
        case 6, 7: return String(localized: "Snow")
        case 8: return String(localized: "Thunderstorms")
        case 10: return String(localized: "Windy")
        default: return String(localized: "Cloudy")
        }
    }

    private static func makeSnapshot(current: CurrentWeather, hourly: Forecast<HourWeather>,
                                     daily: Forecast<DayWeather>, city: String, useMetric: Bool) -> WeatherSnapshot {
        func convert(_ measurement: Measurement<UnitTemperature>) -> Int {
            let unit: UnitTemperature = useMetric ? .celsius : .fahrenheit
            return Int(measurement.converted(to: unit).value.rounded())
        }

        let unitCode = useMetric ? "c" : "f"
        let today = daily.first
        let currentCondId = condId(for: current.condition, isDaylight: current.isDaylight)

        let hourPoints = hourly.prefix(3).map { hour in
            WeatherSnapshot.HourPoint(hour: Calendar.current.component(.hour, from: hour.date),
                                      condId: condId(for: hour.condition, isDaylight: hour.isDaylight),
                                      temp: convert(hour.temperature))
        }

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.setLocalizedDateFormatFromTemplate("EEE")
        let dayPoints = daily.prefix(3).map { day in
            WeatherSnapshot.DayPoint(day: weekdayFormatter.string(from: day.date),
                                     condId: condId(for: day.condition, isDaylight: true),
                                     high: convert(day.highTemperature),
                                     low: convert(day.lowTemperature))
        }

        return WeatherSnapshot(
            unit: unitCode,
            city: city,
            temp: convert(current.temperature),
            high: today.map { convert($0.highTemperature) } ?? convert(current.temperature),
            low: today.map { convert($0.lowTemperature) } ?? convert(current.temperature),
            rain: Int(((today?.precipitationChance ?? 0) * 100).rounded()),
            uv: current.uvIndex.value,
            message: message(for: currentCondId),
            condId: currentCondId,
            forecastDay: Array(hourPoints),
            forecastWeek: Array(dayPoints))
    }
}

extension WeatherProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let id = self.pendingLocation?.id else { return }
            self.finishLocation(id: id, result: locations.last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard let id = self.pendingLocation?.id else { return }
            self.finishLocation(id: id, result: nil)
        }
    }
}
