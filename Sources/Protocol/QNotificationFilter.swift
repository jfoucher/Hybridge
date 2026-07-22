import Foundation

/// Vibration patterns accepted in a Q notification-filter entry (TLV 0xC3).
/// Values observed in the official iOS app's file: 1 for calls, 2 for texts,
/// 4 for apps — 1/2/3 match GB's misfit triple/double/single-short enum;
/// 4 is the official app's default for app alerts.
enum QVibrationPattern: UInt8, Codable, CaseIterable {
    case standard = 4
    case singleShort = 3
    case doubleShort = 2
    case tripleShort = 1
    case singleLong = 8
    case silent = 9

    var label: String {
        switch self {
        case .standard: return String(localized: "Standard")
        case .singleShort: return String(localized: "Single")
        case .doubleShort: return String(localized: "Double")
        case .tripleShort: return String(localized: "Triple")
        case .singleLong: return String(localized: "Long")
        case .silent: return String(localized: "Silent")
        }
    }
}

/// One notification alert on a hands-only Q watch: when a matching ANCS
/// notification arrives, the hands move to `degrees` and the watch vibrates.
struct QNotificationAlert: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// Matches an app by CRC of its bundle id — one filter entry.
        case app
        /// Matches calls/texts from one contact by display name — expands to
        /// a paired call + SMS entry like the official app writes.
        case contact
    }

    var id = UUID()
    var kind: Kind
    /// App alerts: the iOS bundle id. Contact alerts: the contact's display
    /// name exactly as iOS shows it in call/text notifications.
    var identifier: String
    /// Name shown in our UI (for contacts this equals `identifier`).
    var displayName: String
    /// Hand target, 0–359°. Both hands point together, like the official
    /// app. 12 o'clock is stored as 359 (also the official convention).
    var degrees: Int
    var vibration: QVibrationPattern = .standard

    /// Clock position → degrees the way the official app maps them
    /// (1 h = 30°, …, 12 h = 359°).
    static func degrees(forClockPosition position: Int) -> Int {
        position >= 12 ? 359 : position * 30
    }
}

/// Builds the NOTIFICATION_FILTER (0x0C00) file for non-HR Q hybrids,
/// byte-exact against a dump written by the official iOS app
/// (notificationFilter_0C003.bin, captured from a real Q Grant):
/// per entry [len u16] then TLVs — optional 0x02 contact name (NUL-
/// terminated), 0x04 CRC32(bundle id + NUL) LE, 0x80 group, 0xC1 priority
/// 0x00, 0xC2 movement (five i16: hour°, min°, subEye −1, duration 10000,
/// −2), 0xC3 vibration, 0xC4 0.
enum QNotificationFilterFile {
    static let phoneBundleId = "com.apple.mobilephone"
    static let smsBundleId = "com.apple.MobileSMS"

    static func encode(_ alerts: [QNotificationAlert]) -> Data {
        var buffer = Data()
        var entries = 0
        for alert in alerts {
            switch alert.kind {
            case .app:
                appendEntry(&buffer, name: nil,
                            crc: AppNotificationFilter.ancsCrc(alert.identifier),
                            group: 2, degrees: alert.degrees,
                            vibration: alert.vibration.rawValue)
                entries += 1
            case .contact:
                // The official app writes a fixed pair per contact:
                // calls (group 1, triple short) + texts (group 2, double).
                appendEntry(&buffer, name: alert.identifier,
                            crc: AppNotificationFilter.ancsCrc(phoneBundleId),
                            group: 1, degrees: alert.degrees,
                            vibration: QVibrationPattern.tripleShort.rawValue)
                appendEntry(&buffer, name: alert.identifier,
                            crc: AppNotificationFilter.ancsCrc(smsBundleId),
                            group: 2, degrees: alert.degrees,
                            vibration: QVibrationPattern.doubleShort.rawValue)
                entries += 2
            }
        }
        // GB duplicates a single-entry file (syncNotificationSettings) — a
        // firmware quirk workaround; keep parity.
        if entries == 1 {
            buffer.append(buffer)
        }
        return buffer
    }

    /// Quiet-hours file: one stub app entry whose bundle id matches nothing
    /// real (so its CRC never fires), silent vibration, hands parked at 0°.
    /// Satisfies the never-push-empty rule while blocking every real alert.
    /// Flag: stub-blocks-all needs on-watch verification on the Q Grant.
    static func nightFilter() -> Data {
        encode([QNotificationAlert(kind: .app, identifier: "eu.sixpixels.hybridge.quiet",
                                   displayName: "Quiet hours", degrees: 0, vibration: .silent)])
    }

    private static func appendEntry(_ buffer: inout Data, name: String?,
                                    crc: Data, group: UInt8, degrees: Int,
                                    vibration: UInt8) {
        var body = Data()
        if let name {
            let nameBytes = name.nullTerminatedUTF8()
            body.append(contentsOf: [0x02, UInt8(nameBytes.count)])
            body.append(nameBytes)
        }
        body.append(contentsOf: [0x04, 4])
        body.append(crc)
        body.append(contentsOf: [0x80, 1, group])
        body.append(contentsOf: [0xC1, 1, 0x00])
        body.append(contentsOf: [0xC2, 10])
        body.appendInt16LE(Int16(degrees))   // hour hand
        body.appendInt16LE(Int16(degrees))   // minute hand
        body.appendInt16LE(-1)               // sub-eye: don't move
        body.appendInt16LE(10000)            // duration ms
        body.appendInt16LE(-2)
        body.append(contentsOf: [0xC3, 1, vibration])
        body.append(contentsOf: [0xC4, 1, 0x00])
        buffer.appendUInt16LE(UInt16(body.count))
        buffer.append(body)
    }
}
