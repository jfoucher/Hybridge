import Foundation

/// A daily block-everything window (e.g. bedtime). Only one window is
/// supported, always blocking all notifications while active — no per-level
/// picker.
struct QuietSchedule: Codable, Equatable {
    var enabled = false
    var startMinutes = 22 * 60   // 22:00
    var endMinutes = 7 * 60      // 07:00 (overnight wrap supported)
}

enum QuietMode: String, Codable, CaseIterable {
    case day, night
}

/// Pure scheduling math for quiet hours — no watch/UserDefaults access, so
/// it's fully unit-testable.
enum QuietHours {
    /// Desired mode at `now`, handling the midnight wrap (start > end). A
    /// disabled or degenerate (start == end) schedule is always day.
    static func desiredMode(schedule: QuietSchedule, now: Date, calendar: Calendar = .current) -> QuietMode {
        guard schedule.enabled, schedule.startMinutes != schedule.endMinutes else { return .day }
        let minutes = minutesSinceMidnight(now, calendar: calendar)
        let start = schedule.startMinutes
        let end = schedule.endMinutes
        let inWindow = start < end
            ? (minutes >= start && minutes < end)
            : (minutes >= start || minutes < end)
        return inWindow ? .night : .day
    }

    /// The next Date after `now` at which `desiredMode` would change, or nil
    /// if the schedule is disabled/degenerate. Used to give BGAppRefreshTask
    /// an opportunistic earliest-begin-date near the boundary.
    static func nextBoundary(schedule: QuietSchedule, now: Date, calendar: Calendar = .current) -> Date? {
        guard schedule.enabled, schedule.startMinutes != schedule.endMinutes else { return nil }
        let targetMinutes = desiredMode(schedule: schedule, now: now, calendar: calendar) == .day
            ? schedule.startMinutes : schedule.endMinutes
        var dayStart = calendar.startOfDay(for: now)
        // A boundary lands today, tomorrow, or (only for a same-instant edge
        // case) the day after — three tries is always enough.
        for _ in 0..<3 {
            if let candidate = calendar.date(byAdding: .minute, value: targetMinutes, to: dayStart),
               candidate > now {
                return candidate
            }
            dayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        }
        return nil
    }

    private static func minutesSinceMidnight(_ date: Date, calendar: Calendar) -> Int {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}

/// A manual/intent override that wins over the schedule until it expires (at
/// the schedule's next boundary) or is cleared.
private struct QuietOverride: Codable {
    var mode: QuietMode
    var expiry: Date?
}

/// Keeps the watch's notification filter in sync with the user's quiet-hours
/// schedule. The schedule and manual override are global preferences; the
/// last applied mode remains per-watch so every watch receives the filter.
final class QuietHoursManager {
    static let shared = QuietHoursManager()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func globalKey(_ base: WatchScopedKey) -> String { base.rawValue }
    private func appliedKey() -> String { WatchScoped.key(.quietModeApplied) }

    var schedule: QuietSchedule {
        get {
            guard let data = defaults.data(forKey: globalKey(.quietSchedule)),
                  let decoded = try? JSONDecoder().decode(QuietSchedule.self, from: data)
            else { return QuietSchedule() }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: globalKey(.quietSchedule))
            }
        }
    }

    /// The active override's mode, if any and not expired — for UI display.
    var overrideMode: QuietMode? {
        guard let override = loadOverride(), !isExpired(override) else { return nil }
        return override.mode
    }

    /// What `evaluate()` would push right now (schedule + override
    /// resolved), without touching the watch. For UI display.
    var effectiveMode: QuietMode {
        overrideMode ?? QuietHours.desiredMode(schedule: schedule, now: Date())
    }

    /// Sets or clears the manual override and re-evaluates immediately
    /// (pushes right away if connected; otherwise applies on next connect).
    /// nil returns to the schedule (or always-day if the schedule is off).
    func setOverride(_ mode: QuietMode?) async {
        if let mode {
            let expiry = QuietHours.nextBoundary(schedule: schedule, now: Date())
            saveOverride(QuietOverride(mode: mode, expiry: expiry))
        } else {
            defaults.removeObject(forKey: globalKey(.quietOverride))
        }
        await evaluate()
    }

    /// Pushes the matching notification filter if the desired mode changed
    /// since the last push and the watch is connected/idle. Errors are
    /// logged, not thrown — the next evaluation (init/maintenance/foreground)
    /// retries.
    func evaluate() async {
        let desired = effectiveMode
        let applied = defaults.string(forKey: appliedKey()).flatMap(QuietMode.init(rawValue:))
        guard desired != applied else { return }
        let kind = WatchRegistry.activeKindSync()
        guard kind.hasQuietHours else {
            WatchManager.shared.addLog("Quiet hours: unavailable for this watch in release builds pending hardware validation")
            return
        }
        let watch = WatchManager.shared
        let ready = await MainActor.run { watch.connectionState == .ready }
        // Don't pile onto a running init — unless we *are* the init sequence.
        // Both family inits call this near their tail (so a watch reconnecting
        // at 23:00 goes quiet immediately rather than waiting for the next
        // maintenance tick), and they hold `initInProgress` for their whole
        // duration, so a bare check made that call a silent no-op. Holding the
        // session is exactly the "it is safe for us to talk to the watch"
        // condition the flag was standing in for.
        guard ready, !WatchManager.initInProgress || WatchSession.isHeld else { return }
        do {
            if kind == .fossilQ {
                try await watch.setQNotificationFilter(night: desired == .night)
            } else {
                try await watch.setNotificationFilter(night: desired == .night)
            }
            defaults.set(desired.rawValue, forKey: appliedKey())
            watch.addLog("Quiet hours: switched to \(desired.rawValue)")
        } catch {
            watch.addLog("Quiet hours: filter push failed: \(error.localizedDescription)")
        }
    }

    /// Records that the user's *day* notification filter was just written to
    /// the active watch (by setNotificationConfigurations / the Q equivalent,
    /// e.g. during init or from the notification settings screen).
    ///
    /// Without this, an overnight reconnect ran init — which pushes the day
    /// filter — while `quietModeApplied` still read `.night`, so the next
    /// `evaluate()` saw desired == applied == night and returned, leaving the
    /// day filter in place all night. Marking the applied mode as `.day` here
    /// forces `evaluate()` to re-push the night filter when a quiet window is
    /// currently active. Init calls `evaluate()` immediately afterwards; other
    /// callers get it on the next maintenance/foreground tick.
    func noteDayFilterApplied() {
        defaults.set(QuietMode.day.rawValue, forKey: appliedKey())
    }

    private func loadOverride() -> QuietOverride? {
        guard let data = defaults.data(forKey: globalKey(.quietOverride)) else { return nil }
        return try? JSONDecoder().decode(QuietOverride.self, from: data)
    }

    private func saveOverride(_ override: QuietOverride) {
        if let data = try? JSONEncoder().encode(override) {
            defaults.set(data, forKey: globalKey(.quietOverride))
        }
    }

    private func isExpired(_ override: QuietOverride) -> Bool {
        guard let expiry = override.expiry else { return false }
        return Date() >= expiry
    }
}
