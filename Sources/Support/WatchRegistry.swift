import Foundation

/// One watch the app knows about. The protocol never exposes a serial
/// number, so the CoreBluetooth peripheral UUID is the per-unit identity —
/// it keys the keychain entry and settings that truly belong to one watch.
struct KnownWatch: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var modelNumber: String?
    var addedDate: Date
    var lastConnectedDate: Date?
    /// Hardware family, detected from the firmware string on first connect.
    /// nil (including rosters saved before this field existed) means "not
    /// detected yet" and is treated as Hybrid HR.
    var kind: WatchKind?
    var firmware: String?
}

extension Notification.Name {
    /// Posted on main after the active watch changes; per-watch stores and
    /// screens reload their state from the newly scoped keys.
    static let activeWatchChanged = Notification.Name("activeWatchChanged")
}

/// The roster of known watches and which one is active. UserDefaults is the
/// source of truth (it is thread-safe, and WatchManager reads on bleQueue
/// via the *Sync helpers); the @Published mirrors are for SwiftUI and are
/// updated on main.
final class WatchRegistry: ObservableObject {
    static let shared: WatchRegistry = {
        // Whichever singleton is touched first (this or WatchManager) runs
        // the one-time migration before reading any migrated key.
        AppMigrations.run()
        return WatchRegistry()
    }()

    static let watchesKey = "knownWatches"
    static let activeKey = "activeWatchID"

    @Published private(set) var watches: [KnownWatch]
    @Published private(set) var activeWatchID: UUID?

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watches = Self.decodeWatches(from: defaults)
        activeWatchID = Self.decodeActiveID(from: defaults)
    }

    var isEmpty: Bool { watches.isEmpty }
    var activeWatch: KnownWatch? { watches.first { $0.id == activeWatchID } }

    func watch(_ id: UUID) -> KnownWatch? { watches.first { $0.id == id } }

    // MARK: - Mutations (safe from any thread)

    /// Adds a watch to the roster (idempotent). A key saved before
    /// multi-watch, or restored from a device backup, still lives under the
    /// legacy keychain account — adopt it for the first watch that needs one.
    @discardableResult
    func register(id: UUID, name: String) -> KnownWatch {
        var registered: KnownWatch!
        mutate { list in
            if let existing = list.first(where: { $0.id == id }) {
                registered = existing
            } else {
                registered = KnownWatch(id: id, name: name, modelNumber: nil,
                                        addedDate: Date(), lastConnectedDate: nil,
                                        kind: nil, firmware: nil)
                list.append(registered)
            }
        }
        if KeychainStore.loadKey(for: id) == nil, let legacy = KeychainStore.loadLegacyKey() {
            KeychainStore.saveKey(legacy, for: id)
            KeychainStore.deleteLegacyKey()
        }
        return registered
    }

    func setActive(_ id: UUID?) {
        lock.lock()
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeKey)
        } else {
            defaults.removeObject(forKey: Self.activeKey)
        }
        lock.unlock()
        onMain {
            self.activeWatchID = id
            NotificationCenter.default.post(name: .activeWatchChanged, object: id)
        }
    }

    func rename(_ id: UUID, to name: String) {
        mutate { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].name = name
        }
    }

    func updateModel(_ id: UUID, model: String) {
        mutate { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].modelNumber = model
        }
    }

    func updateKind(_ id: UUID, kind: WatchKind, firmware: String) {
        mutate { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].kind = kind
            list[index].firmware = firmware
        }
    }

    func touchLastConnected(_ id: UUID) {
        mutate { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].lastConnectedDate = Date()
        }
    }

    func remove(_ id: UUID) {
        mutate { list in
            list.removeAll { $0.id == id }
        }
    }

    // MARK: - Thread-safe snapshots (for bleQueue callers)

    static func activeWatchIDSync() -> UUID? { decodeActiveID(from: .standard) }

    /// Kind of the active watch for bleQueue callers. Watches never seen by
    /// kind detection are HRs (the only family the app supported before).
    static func activeKindSync() -> WatchKind {
        guard let id = activeWatchIDSync(),
              let kind = knownWatchesSync().first(where: { $0.id == id })?.kind
        else { return .hybridHR }
        return kind
    }
    static func knownWatchesSync() -> [KnownWatch] { decodeWatches(from: .standard) }
    static func hasWatchesSync() -> Bool { UserDefaults.standard.data(forKey: watchesKey) != nil && !knownWatchesSync().isEmpty }

    // MARK: - Plumbing

    /// Read-modify-write against UserDefaults under the lock, then mirror
    /// the result into the @Published property on main.
    private func mutate(_ change: (inout [KnownWatch]) -> Void) {
        lock.lock()
        var list = Self.decodeWatches(from: defaults)
        change(&list)
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.watchesKey)
        }
        lock.unlock()
        onMain { self.watches = list }
    }

    private func onMain(_ update: @escaping () -> Void) {
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    private static func decodeWatches(from defaults: UserDefaults) -> [KnownWatch] {
        guard let data = defaults.data(forKey: watchesKey),
              let list = try? JSONDecoder().decode([KnownWatch].self, from: data) else { return [] }
        return list
    }

    private static func decodeActiveID(from defaults: UserDefaults) -> UUID? {
        defaults.string(forKey: activeKey).flatMap(UUID.init)
    }
}

/// Namespaces per-watch UserDefaults keys as "<base>.<watch UUID>". With no
/// active watch (empty roster) the bare key is used, which keeps the
/// pre-roster first-run flow working.
/// Every per-watch UserDefaults key.
///
/// This is an enum rather than a list of string literals so that the set of
/// keys and the set of keys `WatchScoped.purge` clears cannot drift apart:
/// adding a case is the only way to get a scoped key, and `allCases` drives
/// the purge. They did drift while it was a hand-maintained array — the four
/// `body*` keys were being written but never purged, so forgetting a watch
/// left its owner's age, gender, height and weight behind in UserDefaults.
enum WatchScopedKey: String, CaseIterable {
    case storedAlarms
    case buttonSelections
    case watchTranslations
    case notificationIconEntries
    case notificationIconsEnabled
    case notificationAllApps
    case customWidgetUpper
    case customWidgetLower
    case vibrationStrength
    case activeWatchfaceName
    case jsonPushIndex
    case batteryAlertWarned
    case qNotificationAlerts
    case qButtonFunctions
    case qMultiPressActions
    case quietSchedule
    case quietModeApplied
    case quietOverride
    // These profile keys used to be per-watch. They remain reserved here so
    // v1 namespaced copies can be migrated and purged; current writes use the
    // bare global key because Settings applies one profile to every HR watch.
    case bodyHeightCm
    case bodyWeightKg
    case bodyGender
    case bodyBirth
}

enum WatchScoped {
    /// Base keys, derived from `WatchScopedKey` so it cannot fall out of date.
    /// The one-time migration moves the bare values into the first watch's
    /// namespace; forgetting a watch purges its scoped variants.
    static var perWatchKeys: [String] { WatchScopedKey.allCases.map(\.rawValue) }

    static func key(_ base: WatchScopedKey, watchID: UUID?) -> String {
        key(base.rawValue, watchID: watchID)
    }

    static func key(_ base: WatchScopedKey) -> String {
        key(base, watchID: WatchRegistry.activeWatchIDSync())
    }

    /// String-based variants, for the migration (which walks `perWatchKeys`
    /// generically). Feature code should use the enum so the compiler keeps
    /// the purge list honest.
    static func key(_ base: String, watchID: UUID?) -> String {
        guard let watchID else { return base }
        return "\(base).\(watchID.uuidString)"
    }

    static func purge(watchID: UUID, defaults: UserDefaults = .standard) {
        for base in perWatchKeys {
            defaults.removeObject(forKey: key(base, watchID: watchID))
        }
    }
}
