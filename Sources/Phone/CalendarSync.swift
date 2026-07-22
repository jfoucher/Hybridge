import Foundation
import EventKit

protocol CalendarPayloadSending: Sendable {
    func sendCalendarPayload(_ payload: Data,
                             token: WatchConnectionToken) async -> Bool
}

extension WatchManager: CalendarPayloadSending {
    func sendCalendarPayload(_ payload: Data,
                             token: WatchConnectionToken) async -> Bool {
        guard validatesConnectionToken(token) else { return false }
        return await pushJsonWhenIdle(payload, expectedToken: token)
    }
}

/// Calendar → watch push (GB: FossilHRWatchAdapter.java:1642-1715). A single
/// fire-and-forget JSON push (no req/ack cycle) to whichever app config key
/// consumes `_.config.events` — the stock watchface uses `customWatchFace`.
@MainActor
final class CalendarSync: NSObject, ObservableObject {
    static let shared = CalendarSync()

    nonisolated private static let enabledKey = "calendarSyncEnabled"
    nonisolated private static let lastSyncedHashKey = "calendarSyncLastHash"
    nonisolated private static let lastFailedAttemptKey = "calendarSyncLastFailure"
    nonisolated static let payloadSchema = 1
    nonisolated static let maxEvents = 5
    nonisolated static let lookaheadDays = 7
    nonisolated static let maxFieldLength = 40

    @Published var lastSyncDate: Date?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private let store = EKEventStore()
    private let sender: CalendarPayloadSending
    private var observing = false

    private override convenience init() {
        self.init(sender: WatchManager.shared)
    }

    init(sender: CalendarPayloadSending) {
        self.sender = sender
        super.init()
        if isEnabled { observeChanges() }
    }

    private func observeChanges() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                                name: .EKEventStoreChanged, object: store)
    }

    @objc private func storeChanged() {
        Task { await syncIfEnabled() }
    }

    /// Requests access on first use (if needed), then syncs. Used by the
    /// Settings toggle and the manual "Sync now" button.
    func syncNow() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != .fullAccess {
            do {
                guard try await store.requestFullAccessToEvents() else {
                    WatchManager.shared.addLog("Calendar access denied")
                    return
                }
            } catch {
                WatchManager.shared.addLog("Calendar access request failed: \(error.localizedDescription)")
                return
            }
        }
        observeChanges()
        await sync()
    }

    /// Safe to call from connect / store-changed triggers: never prompts.
    func syncIfEnabled() async {
        guard isEnabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        await sync()
    }

    private func sync() async {
        guard let token = WatchManager.shared.connectionTokenSync(),
              WatchManager.shared.validatesConnectionToken(token) else { return }
        let events = fetchUpcomingEvents()
        let hash = Self.dedupeKey(for: events)
        let deliveryKey = Self.deliveryKey(for: token.watchID)
        guard UserDefaults.standard.object(forKey: deliveryKey) as? Int != hash else {
            lastSyncDate = Date()
            return
        }
        let sent = await sender.sendCalendarPayload(
            JsonPayloads.calendarEventsPush(events), token: token)
        guard Self.commitDelivery(hash: hash, watchID: token.watchID, sent: sent,
                                  tokenStillValid: WatchManager.shared.validatesConnectionToken(token)) else {
            WatchManager.shared.addLog("Calendar: delivery failed; will retry")
            return
        }
        lastSyncDate = Date()
        WatchManager.shared.addLog("Calendar: pushed \(events.count) event(s)")
    }

    nonisolated static func deliveryKey(for watchID: UUID) -> String {
        "\(lastSyncedHashKey).v\(payloadSchema).\(watchID.uuidString)"
    }

    nonisolated static func failureKey(for watchID: UUID) -> String {
        "\(lastFailedAttemptKey).v\(payloadSchema).\(watchID.uuidString)"
    }

    nonisolated static func invalidateDelivery(for watchID: UUID) {
        UserDefaults.standard.removeObject(forKey: deliveryKey(for: watchID))
    }

    /// Transaction boundary kept independent of EventKit/CoreBluetooth so a
    /// failed send or stale post-await token can be regression-tested without
    /// either system framework. Only an acknowledged, still-authorized send
    /// advances the per-watch/schema delivery marker.
    @discardableResult
    nonisolated static func commitDelivery(hash: Int, watchID: UUID, sent: Bool,
                                           tokenStillValid: Bool,
                                           defaults: UserDefaults = .standard) -> Bool {
        guard sent, tokenStillValid else {
            defaults.set(Date(), forKey: failureKey(for: watchID))
            return false
        }
        defaults.set(hash, forKey: deliveryKey(for: watchID))
        defaults.removeObject(forKey: failureKey(for: watchID))
        return true
    }

    private func fetchUpcomingEvents() -> [CalendarEventPayload] {
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: Self.lookaheadDays, to: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(Self.maxEvents)

        return events.map { event in
            let reminders = (event.alarms ?? []).map { alarm -> Int in
                let date = alarm.absoluteDate ?? event.startDate.addingTimeInterval(alarm.relativeOffset)
                return Int(date.timeIntervalSince1970)
            }
            return CalendarEventPayload(
                id: Self.stableId(for: event.eventIdentifier ?? "\(event.startDate.timeIntervalSince1970)-\(event.title ?? "")"),
                title: Self.truncate(event.title ?? ""),
                desc: Self.truncate(event.notes ?? ""),
                start: Int(event.startDate.timeIntervalSince1970),
                end: Int(event.endDate.timeIntervalSince1970),
                reminders: reminders)
        }
    }

    nonisolated static func truncate(_ text: String, to limit: Int = maxFieldLength) -> String {
        String(text.prefix(limit))
    }

    /// Deterministic dedupe key over the structured events, independent of
    /// `JSONSerialization`'s unspecified (and not always stable, even for
    /// two calls with identical input) dictionary key ordering.
    nonisolated static func dedupeKey(for events: [CalendarEventPayload]) -> Int {
        var text = ""
        for event in events {
            text += "\(event.id)|\(event.title)|\(event.desc)|\(event.start)|\(event.end)|\(event.reminders)|"
        }
        return Int(Checksums.crc32(Data(text.utf8)))
    }

    /// FNV-1a 64-bit hash, sign bit cleared so it fits a positive 63-bit int
    /// — the watch only needs uniqueness, not a meaningful value.
    nonisolated static func stableId(for identifier: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int64(hash & 0x7FFF_FFFF_FFFF_FFFF)
    }
}
