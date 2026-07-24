import Foundation
import EventKit

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

/// Where a quiet-mode decision came from — surfaced in the UI so an
/// otherwise-invisible calendar signal is explainable ("Quiet (meeting)" vs.
/// "Quiet (scheduled)").
enum QuietSource {
    case off, override, schedule, calendarBusy, both
}

struct QuietStatus {
    let mode: QuietMode
    let source: QuietSource
}

/// Keeps the watch's notification filter in sync with the user's quiet-hours
/// schedule. The schedule, manual override, and calendar-busy toggle are
/// global preferences; the last applied mode remains per-watch so every
/// watch receives the filter.
final class QuietHoursManager: @unchecked Sendable {
    static let shared = QuietHoursManager()

    private let defaults: UserDefaults
    private let busyProvider: BusyIntervalProviding
    private let calendarObserverLock = NSLock()
    private var calendarObserverToken: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, busyProvider: BusyIntervalProviding = CalendarBusyProvider.shared) {
        self.defaults = defaults
        self.busyProvider = busyProvider
        if calendarQuietEnabled { startObservingCalendarIfNeeded() }
    }

    private func globalKey(_ base: WatchScopedKey) -> String { base.rawValue }
    private func appliedKey(watchID: UUID?) -> String {
        WatchScoped.key(.quietModeApplied, watchID: watchID)
    }

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

    /// Whether the watch should also go quiet during calendar events marked
    /// Busy/Unavailable that the user organized or accepted (not all-day).
    /// Global preference, same storage shape as `schedule`/`overrideMode`.
    var calendarQuietEnabled: Bool {
        get { defaults.bool(forKey: globalKey(.calendarQuietEnabled)) }
        set { defaults.set(newValue, forKey: globalKey(.calendarQuietEnabled)) }
    }

    /// What `evaluate()` would push right now (override, schedule, and
    /// calendar-busy resolved), without touching the watch. For UI display.
    /// Union precedence: quiet if the schedule window is active OR a
    /// calendar-busy event is happening; a manual override wins over both.
    var status: QuietStatus {
        if let overrideMode { return QuietStatus(mode: overrideMode, source: .override) }
        let now = Date()
        let scheduleNight = QuietHours.desiredMode(schedule: schedule, now: now) == .night
        let calendarBusy = calendarQuietEnabled
            && CalendarBusy.isBusy(busyProvider.busyIntervals(now: now), now: now)
        switch (scheduleNight, calendarBusy) {
        case (true, true): return QuietStatus(mode: .night, source: .both)
        case (true, false): return QuietStatus(mode: .night, source: .schedule)
        case (false, true): return QuietStatus(mode: .night, source: .calendarBusy)
        case (false, false): return QuietStatus(mode: .day, source: .off)
        }
    }

    var effectiveMode: QuietMode { status.mode }

    /// The next Date after `now` at which `status.mode` would change absent
    /// a manual override — the schedule boundary, or (if calendar-busy
    /// detection is on) whichever of the schedule/calendar boundaries comes
    /// first. Used to give `BGAppRefreshTask` an opportunistic
    /// earliest-begin-date. Reads the calendar cache as-is (no refresh) —
    /// callers that need it fresh should `await busyProvider.refresh` first,
    /// as `evaluate()` does.
    func nextBoundary(now: Date) -> Date? {
        let scheduleBoundary = QuietHours.nextBoundary(schedule: schedule, now: now)
        guard calendarQuietEnabled else { return scheduleBoundary }
        let calendarBoundary = CalendarBusy.nextBoundary(busyProvider.busyIntervals(now: now), now: now)
        return [scheduleBoundary, calendarBoundary].compactMap { $0 }.min()
    }

    /// Sets or clears the manual override and re-evaluates immediately
    /// (pushes right away if connected; otherwise applies on next connect).
    /// nil returns to the schedule (or always-day if the schedule is off).
    func setOverride(_ mode: QuietMode?) async {
        if let mode {
            let expiry = nextBoundary(now: Date())
            saveOverride(QuietOverride(mode: mode, expiry: expiry))
        } else {
            defaults.removeObject(forKey: globalKey(.quietOverride))
        }
        await evaluate()
    }

    /// Enables/disables the calendar-busy trigger. Turning it on requests
    /// calendar access first (a no-op prompt if already granted, e.g. via
    /// the calendar-sync toggle) and returns `false` without enabling if
    /// denied. Turning off never prompts and always succeeds.
    @discardableResult
    func setCalendarQuietEnabled(_ on: Bool) async -> Bool {
        if on {
            guard await busyProvider.requestAccessIfNeeded() else { return false }
            startObservingCalendarIfNeeded()
        }
        calendarQuietEnabled = on
        await evaluate()
        return true
    }

    /// Lazily starts listening for calendar changes so an edited/cancelled
    /// meeting is picked up promptly. Mirrors `CalendarSync.observeChanges()`
    /// — added once, never torn down (a fire while disabled just triggers a
    /// harmless no-op `evaluate()`).
    private func startObservingCalendarIfNeeded() {
        calendarObserverLock.withLock {
            guard calendarObserverToken == nil else { return }
            calendarObserverToken = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: nil, queue: nil
            ) { [weak self] _ in
                Task { await self?.evaluate() }
            }
        }
    }

    /// Pushes the matching notification filter if the desired mode changed
    /// since the last push and the watch is connected/idle. Errors are
    /// logged, not thrown — the next evaluation (init/maintenance/foreground)
    /// retries.
    func evaluate() async {
        let watch = WatchManager.shared
        guard let token = WatchSession.connectionToken ?? watch.connectionTokenSync(),
              watch.validatesConnectionToken(token) else { return }
        if calendarQuietEnabled {
            await busyProvider.refresh(now: Date())
        }
        let desired = effectiveMode
        let key = appliedKey(watchID: token.watchID)
        let applied = defaults.string(forKey: key).flatMap(QuietMode.init(rawValue:))
        guard desired != applied else { return }
        let kind = token.kind
        guard kind.hasQuietHours else {
            WatchManager.shared.addLog("Quiet hours: unavailable for this watch in release builds pending hardware validation")
            return
        }
        // Evaluate against *this token's* connection, not the active one —
        // in a multi-watch fleet the quiet-hours evaluate can target a
        // non-active watch.
        let connection = WatchFleet.shared.connection(for: token.watchID)
        let ready = await MainActor.run { connection?.connectionState == .ready }
        // Don't pile onto a running init — unless we *are* the init sequence.
        // Both family inits call this near their tail (so a watch reconnecting
        // at 23:00 goes quiet immediately rather than waiting for the next
        // maintenance tick), and they hold this watch's session for their whole
        // duration, so a bare check made that call a silent no-op. Holding the
        // session is exactly the "it is safe for us to talk to the watch"
        // condition the flag was standing in for.
        guard ready,
              !(connection?.isInitializing ?? false) || WatchSession.holds(token.watchID)
        else { return }
        do {
            try await WatchSession.exclusive(for: token) {
                guard watch.validatesConnectionToken(token) else {
                    throw FossilError.staleConnection
                }
                if kind == .fossilQ {
                    try await watch.setQNotificationFilter(night: desired == .night)
                } else {
                    try await watch.setNotificationFilter(night: desired == .night)
                }
            }
            guard watch.validatesConnectionToken(token) else { return }
            defaults.set(desired.rawValue, forKey: key)
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
        let watchID = WatchSession.connectionToken?.watchID
            ?? WatchManager.shared.connectionTokenSync()?.watchID
            ?? WatchRegistry.activeWatchIDSync()
        defaults.set(QuietMode.day.rawValue, forKey: appliedKey(watchID: watchID))
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
