import Foundation

/// Everything the widget extension needs to render, mirrored one-way from
/// the app's own stores by `WidgetBridge`. Foundation-only (no WidgetKit
/// import) so it compiles into both the app and extension targets.
struct WidgetSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version = WidgetSnapshot.currentVersion
    var updatedAt: Date
    var watchName: String?
    /// HR (e-ink display) vs Q (hands only) — drives iconography.
    var hasDisplay: Bool
    var todaySteps: Int
    /// The day `todaySteps` belongs to — compared against the timeline
    /// entry's date, never `Date()`, so a widget rendered ahead of time
    /// still knows when its data has gone stale.
    var stepsDate: Date
    /// true = live watch counter, false = last-sync minute-sample sum.
    var stepsAreLive: Bool
    var stepGoal: Int
    var batteryPercent: Int?
    var batteryDate: Date?
    var isConnected: Bool
    var lastSyncDate: Date?

    private static let connectionValiditySeconds: TimeInterval = 15 * 60
    private static let batteryStaleAfterSeconds: TimeInterval = 60 * 60
    private static let batteryHiddenAfterSeconds: TimeInterval = 48 * 60 * 60

    /// Today's step count for display at `date`, or nil once `stepsDate`'s
    /// day has rolled over relative to it.
    func stepsForDisplay(at date: Date, calendar: Calendar = .current) -> Int? {
        guard calendar.isDate(stepsDate, inSameDayAs: date) else { return nil }
        return todaySteps
    }

    /// true only while genuinely connected and recently confirmed so; a
    /// "connected" snapshot surviving app suspension for longer than this is
    /// unreliable, so it downgrades to nil ("last seen…") instead of lying.
    func connectionForDisplay(at date: Date) -> Bool? {
        guard isConnected else { return false }
        guard date.timeIntervalSince(updatedAt) < Self.connectionValiditySeconds else { return nil }
        return true
    }

    /// Battery percent plus a staleness flag ("as of" caveat past 1h);
    /// dropped entirely past 48h as no longer worth showing.
    func batteryForDisplay(at date: Date) -> (percent: Int, isStale: Bool)? {
        guard let batteryPercent, let batteryDate else { return nil }
        let age = date.timeIntervalSince(batteryDate)
        guard age < Self.batteryHiddenAfterSeconds else { return nil }
        return (batteryPercent, age >= Self.batteryStaleAfterSeconds)
    }

    /// Compares only the fields widget views actually render, ignoring
    /// timestamp churn (`updatedAt`/`batteryDate`) — the WidgetBridge reload
    /// gate: a snapshot is always written, but WidgetCenter reloads (budget
    /// ~40-70/day) only fire when this says something visible changed.
    func rendersSameAs(_ other: WidgetSnapshot) -> Bool {
        watchName == other.watchName
            && hasDisplay == other.hasDisplay
            && todaySteps == other.todaySteps
            && stepsDate == other.stepsDate
            && stepsAreLive == other.stepsAreLive
            && stepGoal == other.stepGoal
            && batteryPercent == other.batteryPercent
            && isConnected == other.isConnected
            && lastSyncDate == other.lastSyncDate
    }
}

/// Read/write access to the app-group mirrored snapshot. The app writes,
/// the widget extension only reads.
enum WidgetStore {
    static let appGroupID = "group.eu.sixpixels.hybridge"
    static let snapshotKey = "widgetSnapshot"

    /// nil when the entitlement is missing, nothing has been written yet, or
    /// the stored snapshot is from a version we no longer understand.
    static func load(defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)) -> WidgetSnapshot? {
        guard let defaults, let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    static func save(_ snapshot: WidgetSnapshot, defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }
}
