import Foundation
import EventKit

/// A calendar-event span that should be treated as "busy" for quiet-hours
/// purposes.
struct BusyInterval: Equatable {
    let start: Date
    let end: Date
}

/// Pure — no EventKit/UserDefaults access, so it's fully unit-testable like
/// `QuietHours`.
enum CalendarBusy {
    static func isBusy(_ intervals: [BusyInterval], now: Date) -> Bool {
        intervals.contains { $0.start <= now && now < $0.end }
    }

    /// End of the interval covering `now` if busy, else the start of the
    /// nearest future interval. Nil if nothing in `intervals` is relevant.
    static func nextBoundary(_ intervals: [BusyInterval], now: Date) -> Date? {
        if let end = intervals.filter({ $0.start <= now && now < $0.end }).map(\.end).min() {
            return end
        }
        return intervals.map(\.start).filter { $0 > now }.min()
    }
}

protocol BusyIntervalProviding: Sendable {
    /// Synchronous, no I/O — reads whatever `refresh` last fetched.
    func busyIntervals(now: Date) -> [BusyInterval]
    /// The only method that touches EventKit. Concurrent calls coalesce onto
    /// one in-flight fetch.
    func refresh(now: Date) async
    /// Requests full calendar access if not already granted. Returns whether
    /// access is authorized after the call.
    func requestAccessIfNeeded() async -> Bool
}

/// EventKit-backed `BusyIntervalProviding`. Owns its own `EKEventStore`,
/// deliberately separate from `CalendarSync`'s: that store is only ever
/// touched under `CalendarSync`'s `@MainActor` isolation, while this needs to
/// be called from `QuietHoursManager`'s non-actor-isolated `evaluate()`
/// (background maintenance, BGAppRefreshTask-adjacent paths included) — and
/// Apple documents `EKEventStore` as unsafe to call concurrently from
/// multiple threads, so sharing one instance across both isolation domains
/// would require either constant MainActor round-trips or unsynchronized
/// cross-thread access.
///
/// `busyIntervals(now:)` deliberately never touches EventKit itself — it's
/// read synchronously from hot main-thread SwiftUI paths (quiet-hours
/// "Currently" row, notification screens' quiet badge), and a live
/// `events(matching:)` call there would be a blocking XPC round trip on the
/// main thread on every render. Only `refresh(now:)` queries the store, and
/// it's the sole writer of the cache `busyIntervals` reads.
final class CalendarBusyProvider: BusyIntervalProviding, @unchecked Sendable {
    static let shared = CalendarBusyProvider()

    /// How far ahead of `now` to look for busy events. Bounds both the query
    /// cost and how far out `nextBoundary` can see.
    static let lookahead: TimeInterval = 24 * 60 * 60

    /// Boxes the in-flight `Task` so it can be identity-compared — `Task` is
    /// a struct, so `===` needs a class-constrained wrapper.
    private final class InFlightBox {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
    }

    private let store = EKEventStore()
    private let lock = NSLock()
    private var cached: [BusyInterval] = []
    private var inFlight: InFlightBox?

    func busyIntervals(now: Date) -> [BusyInterval] {
        lock.withLock { cached }
    }

    /// Concurrent callers (e.g. periodic maintenance racing a scene-active
    /// evaluate) await the same in-flight fetch instead of firing two
    /// `events(matching:)` queries at once on the same store instance.
    func refresh(now: Date) async {
        let box = lock.withLock { () -> InFlightBox in
            if let inFlight { return inFlight }
            let box = InFlightBox(Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.performRefresh(now: now)
            })
            inFlight = box
            return box
        }
        await box.task.value
        lock.withLock {
            if inFlight === box { inFlight = nil }
        }
    }

    func requestAccessIfNeeded() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    private func performRefresh(now: Date) async {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            lock.withLock { cached = [] }
            return
        }
        let end = now.addingTimeInterval(Self.lookahead)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let intervals = store.events(matching: predicate)
            .filter(Self.isBusyBlock)
            .map { BusyInterval(start: $0.startDate, end: $0.endDate) }
        lock.withLock { cached = intervals }
    }

    /// Busy/unavailable, not all-day, and either organized or accepted by
    /// the current user. Note: `EKEvent.availability` defaults to
    /// `.notSupported` on calendars whose source doesn't populate it (some
    /// local/third-party-synced calendars), so this can under-detect busy
    /// status there — acceptable, but worth a real-device check across
    /// account types.
    private static func isBusyBlock(_ event: EKEvent) -> Bool {
        guard event.availability == .busy || event.availability == .unavailable,
              !event.isAllDay else { return false }
        return isMineOrAccepted(event)
    }

    private static func isMineOrAccepted(_ event: EKEvent) -> Bool {
        if event.organizer?.isCurrentUser == true { return true }
        guard let attendees = event.attendees else { return true }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .accepted }
    }
}
