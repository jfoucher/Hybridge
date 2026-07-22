import Foundation

/// A Codable value persisted in UserDefaults under a per-watch key.
///
/// Every store below was the same eight lines of get/set with a different type
/// and default; this is that shape, once. The key is resolved on each access
/// rather than captured, so switching the active watch changes what the store
/// reads without anything having to be reloaded.
struct WatchScopedValue<Value: Codable> {
    let key: WatchScopedKey
    let defaultValue: Value
    private let defaults: UserDefaults
    /// Rejects a decoded-but-unusable value (e.g. a button array that isn't
    /// the three the file format requires), falling back to the default.
    private let isValid: (Value) -> Bool

    init(_ key: WatchScopedKey, default defaultValue: Value,
         defaults: UserDefaults = .standard,
         isValid: @escaping (Value) -> Bool = { _ in true }) {
        self.key = key
        self.defaultValue = defaultValue
        self.defaults = defaults
        self.isValid = isValid
    }

    var wrappedValue: Value {
        get {
            guard let data = defaults.data(forKey: WatchScoped.key(key)),
                  let decoded = try? JSONDecoder().decode(Value.self, from: data),
                  isValid(decoded)
            else { return defaultValue }
            return decoded
        }
        nonmutating set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: WatchScoped.key(key))
        }
    }

    /// Drops the stored value, so the next read returns `defaultValue`.
    func reset() {
        defaults.removeObject(forKey: WatchScoped.key(key))
    }
}

/// A Codable preference shared by every watch. Watch-family-specific values
/// still use separate keys, but never the active watch's UUID, so the next
/// compatible watch receives the same configuration during initialization.
struct GlobalSettingsValue<Value: Codable> {
    let key: String
    let defaultValue: Value
    private let defaults: UserDefaults
    private let isValid: (Value) -> Bool

    init(_ key: WatchScopedKey, default defaultValue: Value,
         defaults: UserDefaults = .standard,
         isValid: @escaping (Value) -> Bool = { _ in true }) {
        self.key = key.rawValue
        self.defaultValue = defaultValue
        self.defaults = defaults
        self.isValid = isValid
    }

    var wrappedValue: Value {
        get {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(Value.self, from: data),
                  isValid(decoded)
            else { return defaultValue }
            return decoded
        }
        nonmutating set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }

    func reset() { defaults.removeObject(forKey: key) }
}

/// UserDefaults-backed persistence for the button/commute config the user
/// edits in the UI. Shared by all Hybrid HR watches. 
enum ButtonStore {
    /// The saved button→app mappings, falling back to the stock button
    /// defaults on first launch.
    private static let storage = GlobalSettingsValue(.buttonSelections,
                                                      default: ButtonConfig.defaults)

    static var selections: [ButtonSelection] {
        get { storage.wrappedValue }
        set { storage.wrappedValue = newValue }
    }
}

/// A commuteApp destination. With coordinates set, picking it on the watch
/// gets a live MapKit ETA instead of the static "On your way to …" reply.
struct CommuteDestination: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double?
    var longitude: Double?
    /// "car" | "walk" | "transit" — the MKDirections transport type.
    var transport: String = "car"

    var hasCoordinates: Bool { latitude != nil && longitude != nil }
}

/// Notification alerts for the hands-only Q watches (per-app / per-contact
/// hand positions + vibration, uploaded as the 0x0C00 filter file).
/// Shared by all hands-only Q watches.
enum QNotificationStore {
    private static let storage = GlobalSettingsValue<[QNotificationAlert]>(.qNotificationAlerts,
                                                                            default: [])

    static var alerts: [QNotificationAlert] {
        get { storage.wrappedValue }
        set { storage.wrappedValue = newValue }
    }

    static var hasStoredAlerts: Bool {
        UserDefaults.standard.object(forKey: WatchScopedKey.qNotificationAlerts.rawValue) != nil
    }
}

/// Button functions for the hands-only Q watches (top/middle/bottom, file
/// 0x0600). Shared by compatible watches. Empty until the user configures buttons — the
/// init sequence only uploads a saved config, never defaults, so a config
/// written by the official app survives.
enum QButtonStore {
    /// GB's stock defaults, offered when nothing is saved yet.
    static let defaults: [QButtonFunction] = [.forwardToPhone, .musicControl, .date]

    /// Empty means "the user has never configured buttons", which the init
    /// sequence treats as "don't push anything" so a config written by the
    /// official app survives. The file format is exactly three buttons, so a
    /// stored array of any other length is treated as absent.
    private static let storage = GlobalSettingsValue<[QButtonFunction]>(
        .qButtonFunctions, default: [], isValid: { $0.count == 3 })

    static var functions: [QButtonFunction]? {
        get {
            let stored = storage.wrappedValue
            return stored.count == 3 ? stored : nil
        }
        set {
            if let newValue { storage.wrappedValue = newValue } else { storage.reset() }
        }
    }
}

/// Phone-side action for one press type of a Q button assigned to
/// "Forward to phone (multi-press)" — the watch reports single/double/long
/// presses, the phone decides what they mean. Volume executes on the phone
/// either way (the native volume payloads also just send an event), so e.g.
/// single = volume up, double = volume down puts both on one button.
enum QMultiPressAction: String, CaseIterable, Codable {
    case none
    case volumeUp
    case volumeDown
    case playPause
    case nextTrack
    case previousTrack
    case ringPhone

    var displayName: String {
        switch self {
        case .none: return String(localized: "Nothing")
        case .volumeUp: return String(localized: "Volume up")
        case .volumeDown: return String(localized: "Volume down")
        case .playPause: return String(localized: "Play / pause")
        case .nextTrack: return String(localized: "Next track")
        case .previousTrack: return String(localized: "Previous track")
        case .ringPhone: return String(localized: "Find my phone")
        }
    }
}

/// The three press-type mappings (single, double, long) for multi-press
/// buttons. Shared across compatible watches; phone-side only, so changes apply instantly
/// without re-uploading the button file.
enum QMultiPressStore {
    static let defaults: [QMultiPressAction] = [.volumeUp, .volumeDown, .playPause]

    /// One entry per press type, so anything but three is unusable.
    private static let storage = GlobalSettingsValue(.qMultiPressActions, default: defaults,
                                                      isValid: { $0.count == 3 })

    /// Index 0 = single press, 1 = double, 2 = long.
    static var actions: [QMultiPressAction] {
        get { storage.wrappedValue }
        set { storage.wrappedValue = newValue }
    }
}

/// Commute destinations shown on the watch's commuteApp (GB's Q_ACTIONS).
/// Shared by all compatible watches. (The pre-coordinates string list is resolved by
/// AppMigrations, so no legacy fallback is needed here.)
enum CommuteStore {
    private static let storage = GlobalSettingsValue<[CommuteDestination]>(.commuteDestinations2,
                                                                            default: [])

    static var items: [CommuteDestination] {
        get { storage.wrappedValue }
        set { storage.wrappedValue = newValue }
    }

    /// The names as pushed to `commuteApp._.config.destinations`.
    static var destinations: [String] { items.map(\.name) }

    static func item(named name: String) -> CommuteDestination? {
        items.first { $0.name == name }
    }
}

/// One entry of the on-watch custom menu (rendered by the open-source
/// watchface's menu_structure config; schema verified against
/// open_source_watchface.js). Each item binds to a button slot inside the
/// menu; selecting it runs its action.
struct WatchMenuItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case showMessage    // shows `text` on the watch
        case openApp        // opens watch app named `text`
        case sendToPhone    // sends the label to the phone (answered per `phoneAction`)
    }

    enum PhoneAction: String, Codable, CaseIterable {
        case reply          // answer with `text` as the status line
        case findPhone      // ring the phone, answer "Ringing…"
        case commuteETA     // live ETA to the commute destination in `text`
    }

    var id = UUID()
    var slot: String = "top_short_press_release"
    var label: String = String(localized: "Item")
    var kind: Kind = .showMessage
    var text: String = ""
    var phoneAction: PhoneAction = .reply

    /// The button slots the menu can bind (the face offers no middle_hold).
    static let slots: [(action: String, title: String)] = [
        ("top_short_press_release", String(localized: "Top press")),
        ("middle_short_press_release", String(localized: "Middle press")),
        ("bottom_short_press_release", String(localized: "Bottom press")),
        ("top_hold", String(localized: "Top hold")),
        ("bottom_hold", String(localized: "Bottom hold")),
    ]
}

/// Persists the custom on-watch menu and builds its menu_structure JSON.
/// Shared by all compatible watches.
enum MenuStore {
    private static let itemsKey = WatchScopedKey.watchMenuItems.rawValue
    private static let titleKey = WatchScopedKey.watchMenuTitle.rawValue
    private static let openSlotKey = WatchScopedKey.watchMenuOpenSlot.rawValue
    private static let enabledKey = WatchScopedKey.watchMenuEnabled.rawValue

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var title: String {
        get { UserDefaults.standard.string(forKey: titleKey) ?? String(localized: "Menu") }
        set { UserDefaults.standard.set(newValue, forKey: titleKey) }
    }

    /// Which watchface button event opens the menu (default: top hold).
    static var openSlot: String {
        get { UserDefaults.standard.string(forKey: openSlotKey) ?? "top_hold" }
        set { UserDefaults.standard.set(newValue, forKey: openSlotKey) }
    }

    static var items: [WatchMenuItem] {
        get {
            guard let data = UserDefaults.standard.data(forKey: itemsKey),
                  let decoded = try? JSONDecoder().decode([WatchMenuItem].self, from: data)
            else { return [] }
            return decoded
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: itemsKey) }
    }

    static var hasStoredConfiguration: Bool {
        UserDefaults.standard.object(forKey: enabledKey) != nil
            || UserDefaults.standard.object(forKey: itemsKey) != nil
    }

    static func item(forSentData data: String) -> WatchMenuItem? {
        items.first { $0.kind == .sendToPhone && $0.label == data }
    }

    /// The `customWatchFace._.config.menu_structure` object: the root's
    /// handlers are live on the watchface itself, so one root handler on
    /// `openSlot` opens the menu (is_submenu) containing the items; a back
    /// item is added on the first free slot.
    static func menuStructure() -> [String: Any] {
        guard isEnabled else { return [:] }
        var handlers: [[String: Any]] = items.map { item in
            var handler: [String: Any] = ["action": item.slot, "label": item.label]
            switch item.kind {
            case .showMessage:
                handler["message_displayed_on_action"] = item.text
            case .openApp:
                handler["app_to_open"] = item.text
                handler["action_closes_app"] = true
            case .sendToPhone:
                handler["data_sent_on_action"] = item.label
            }
            return handler
        }
        let used = Set(items.map(\.slot))
        if let free = WatchMenuItem.slots.map(\.action).first(where: { !used.contains($0) }) {
            handlers.append(["action": free, "label": String(localized: "Back"),
                             "action_goes_back": true])
        }
        return [
            "label": title,
            "action_handlers": [
                ["action": openSlot, "label": title,
                 "is_submenu": true, "action_handlers": handlers] as [String: Any],
            ],
        ]
    }

}
