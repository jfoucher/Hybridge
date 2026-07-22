import Foundation

/// The hardware families behind the qhybrid protocol, told apart from the
/// firmware revision string (2A26) — the model number plays no part.
enum WatchKind: String, Codable {
    /// Hybrid HR / Gen 6 — e-ink display, encrypted file protocol, needs the
    /// 16-byte auth key.
    case hybridHR
    /// Newer non-HR Q hybrids (Q Commuter / Activist / Grant era) — physical
    /// hands only, same file protocol as the HR but completely unencrypted.
    case fossilQ
    /// Oldest Q firmware (Misfit command protocol) — detected so we can say
    /// so clearly, but not supported.
    case misfitQ
    /// Firmware string not read yet.
    case unknown

    /// GB's exact rule: prefix IV0/VA/WA or charAt(2)=='1' → HR; otherwise
    /// the firmware major at charAt(6): '0'/'1' → Misfit era, '2' → the
    /// unencrypted fossil file protocol. Strings GB would crash or throw on
    /// map to `.unknown` (treated as HR, today's only known default).
    static func detect(firmware: String) -> WatchKind {
        if firmware.hasPrefix("IV0") || firmware.hasPrefix("VA") || firmware.hasPrefix("WA") {
            return .hybridHR
        }
        let chars = Array(firmware)
        guard chars.count > 2 else { return .unknown }
        if chars[2] == "1" { return .hybridHR }
        guard chars.count > 6 else { return .unknown }
        switch chars[6] {
        case "0", "1": return .misfitQ
        case "2": return .fossilQ
        default: return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .hybridHR: return "Hybrid HR"
        case .fossilQ: return "Q Hybrid"
        case .misfitQ: return String(localized: "Q Hybrid (first gen)")
        case .unknown: return String(localized: "Watch")
        }
    }

    // MARK: - Capabilities
    // The UI and the action layer key off these, never off the kind itself,
    // so a future family lands by picking its flags here. `.unknown` gets the
    // HR flags: every watch registered before kind detection existed is an HR.

    /// Encrypted protocol: auth key required, files AES-wrapped.
    var needsAuthKey: Bool { self != .fossilQ && self != .misfitQ }
    var hasEncryptedFiles: Bool { needsAuthKey }

    /// E-ink display and everything that only makes sense with one.
    var hasDisplay: Bool { self == .hybridHR || self == .unknown }
    var hasWatchfaces: Bool { hasDisplay }
    var hasApps: Bool { hasDisplay }
    var hasJsonPush: Bool { hasDisplay }
    var hasTranslations: Bool { hasDisplay }
    var hasWeather: Bool { hasDisplay }
    var hasCalendar: Bool { hasDisplay }
    var hasQuietHours: Bool { true }

    var hasHeartRate: Bool { hasDisplay }
    var hasWorkouts: Bool { hasDisplay }

    /// Q notifications are hand positions + vibration per app (filter file
    /// 0x0C00 movement entries) instead of icons on a display.
    var hasHandNotificationConfig: Bool { self == .fossilQ }
    /// Q buttons are configured with precompiled blobs in file 0x0600…
    var hasButtonConfigFile: Bool { self == .fossilQ }
    /// …vs the HR way: JSON master config mapping buttons to apps.
    var hasButtonAppMapping: Bool { hasDisplay }

    /// HR charges on a puck; the non-HR Qs run on a replaceable coin cell.
    var hasRechargeableBattery: Bool { self == .hybridHR || self == .unknown }

    /// Non-HR movements can't step a hand by exactly 1° — GB bumps it to 2
    /// (MoveHandsRequest's isHybridHR quirk).
    var movesHandsMinTwoDegrees: Bool { self == .fossilQ || self == .misfitQ }

    /// Physical sub-eye (the small third hand), moved and calibrated as
    /// hand 3. The HR renders its sub-dials on the display instead.
    var hasSubEye: Bool { self == .fossilQ || self == .misfitQ }
}
