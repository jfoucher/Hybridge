import Foundation
import UserNotifications

/// Posts a local notification when the synced watch battery falls below the
/// configured threshold. The watch has no push channel of its own — the level
/// only updates when the app reads the config file — so this fires on sync
/// (foreground or background refresh). The warned flag is kept per watch, so
/// a roster of several watches alerts independently.
final class BatteryWatcher: @unchecked Sendable {
    static let shared = BatteryWatcher()

    private let enabledKey = "batteryAlertEnabled"
    private let thresholdKey = "batteryAlertThreshold"
    static let warnedBaseKey = "batteryAlertWarned"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set {
            defaults.set(newValue, forKey: enabledKey)
            if newValue { requestAuthorization() }
        }
    }

    var threshold: Int {
        get {
            let value = defaults.integer(forKey: thresholdKey)
            return value == 0 ? 15 : value
        }
        set { defaults.set(newValue, forKey: thresholdKey) }
    }

    /// Once warned, the level must climb this many points above the threshold
    /// to re-arm — Q coin-cell readings bounce under load, and a 1-point blip
    /// past the threshold must not produce a second alert.
    static let resetMargin = 5

    /// Pure decision: whether to warn now, and the new warned flag. Readings
    /// in the dead zone (threshold ..< threshold+resetMargin) change nothing.
    static func evaluate(level: Int, threshold: Int, alreadyWarned: Bool)
        -> (warn: Bool, warnedFlag: Bool) {
        if level >= threshold + resetMargin { return (false, false) }
        if level > threshold { return (false, alreadyWarned) }
        return (!alreadyWarned, true)
    }

    /// Call with every fresh battery reading of the active watch.
    func check(level: Int) {
        let watchID = WatchRegistry.activeWatchIDSync()
        guard check(level: level, watchID: watchID) else { return }
        let watch = WatchRegistry.knownWatchesSync().first { $0.id == watchID }
        postNotification(level: level, watchID: watchID,
                         name: watch?.name, kind: watch?.kind ?? .hybridHR)
    }

    /// State machine only (no posting): updates the watch's warned flag and
    /// returns whether an alert is due. Split out so tests can drive it.
    @discardableResult
    func check(level: Int, watchID: UUID?) -> Bool {
        let warnedKey = WatchScoped.key(Self.warnedBaseKey, watchID: watchID)
        guard isEnabled else {
            // Stay armed while disabled, so enabling the alert on an
            // already-low watch still warns on the next reading.
            defaults.set(false, forKey: warnedKey)
            return false
        }
        let (warn, flag) = Self.evaluate(level: level, threshold: threshold,
                                         alreadyWarned: defaults.bool(forKey: warnedKey))
        defaults.set(flag, forKey: warnedKey)
        return warn
    }

    private func postNotification(level: Int, watchID: UUID?, name: String?, kind: WatchKind) {
        let watchName = name ?? kind.displayName
        let advice = kind.hasRechargeableBattery
            ? String(localized: "time to charge it")
            : String(localized: "time to replace its battery")
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Watch battery low")
        content.body = String(localized: "\(watchName) is at \(level, format: .percent) — \(advice).")
        content.sound = .default
        let identifier = watchID.map { "watchBatteryLow.\($0.uuidString)" } ?? "watchBatteryLow"
        let request = UNNotificationRequest(identifier: identifier,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        WatchManager.shared.addLog("Battery alert posted (\(watchName), \(level)%)")
    }

    /// Whether the user has explicitly turned notifications off for the app —
    /// the one state where the alert toggle silently does nothing.
    func permissionDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus == .denied
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                WatchManager.shared.addLog("Battery alert: notification permission denied")
            }
        }
    }
}
