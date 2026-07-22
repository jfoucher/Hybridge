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

/// UserDefaults-backed persistence for the button config the user
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
