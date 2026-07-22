import Foundation

/// One 2-bit icon asset for the watch's notification icon store
/// (GB: NotificationImage). Uploaded concatenated as a cooked file to
/// ASSET_NOTIFICATION_IMAGES (0x0701).
struct WatchNotificationIcon {
    static let maxSide = 24

    let name: String
    let width: Int
    let height: Int
    /// Bare RLE pixel runs ([count][pixel]…, alpha-aware 2-bit pixels) — no
    /// height/width prefix and no FF FF terminator; the block wrapper below
    /// carries those itself (GB: NotificationImagePutRequest.prepareFileData).
    let rleData: Data

    /// [u16LE size][name][0x00][w][h][rle][0xFF 0xFF],
    /// size = nameLen + 3 + rleLen + 2.
    var block: Data {
        let nameBytes = name.utf8Prefix(maxBytes: 240)
        var data = Data()
        data.appendUInt16LE(UInt16(nameBytes.count + 3 + rleData.count + 2))
        data.append(nameBytes)
        data.append(0x00)
        data.append(UInt8(clamping: min(max(width, 0), Self.maxSide)))
        data.append(UInt8(clamping: min(max(height, 0), Self.maxSide)))
        data.append(rleData)
        data.append(contentsOf: [0xFF, 0xFF])
        return data
    }

    static func file(_ icons: [WatchNotificationIcon]) -> Data {
        icons.reduce(into: Data()) { $0.append($1.block) }
    }
}

enum ProtocolInputValidation {
    static let maximumBundleIDBytes = 255
    static let maximumDisplayNameCharacters = 80

    static func normalizedBundleID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumBundleIDBytes else { return nil }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ component in
                  !component.isEmpty && component.utf8.count <= 63
                    && component.utf8.allSatisfy {
                        ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                            || ($0 >= 97 && $0 <= 122) || $0 == 45
                    }
              }) else { return nil }
        return value
    }

    static func displayName(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed)
            .prefix(maximumDisplayNameCharacters))
    }
}

/// Per-app notification filter entry (GB: NotificationHRConfiguration).
/// Once BLE-bonded, the watch hashes the ANCS app identifier (the iOS bundle
/// ID) with CRC32 and looks it up in the filter file to pick the icon.
struct AppNotificationFilter {
    let packageName: String
    /// 4 bytes as stored in the file. The firmware's ANCS matcher computes
    /// **CRC32 of the NUL-terminated bundle id** (little-endian) — cracked
    /// via known-plaintext diffing of two official-iOS-app 0x0C00 dumps and
    /// verified against all 51 entries. GB hashes *without* the NUL, which
    /// only works on Android because GB sends the same CRC in each play
    /// file and the watch just byte-compares (our test path relies on that
    /// too, via the "generic" entry). Empty = no CRC TLV, which the
    /// firmware treats as the catch-all (matches every app).
    let packageCrc: Data
    let iconName: String
    /// GB writes group 0 everywhere; the official app uses 2 for most apps,
    /// 3/4 for some social apps, 5 for calendars, 6 for email, 7 for the
    /// catch-all and user-toggled entries.
    var groupId: UInt8 = 0
    /// GB writes 0xFF everywhere; the official app uses 0x00 for apps and
    /// 0xFF only for the catch-all.
    var priority: UInt8 = 0xFF
    /// The 0xC4 TLV: 1 = entry enabled, 0 = app actively blocked (empty
    /// icon, per the official app's disable toggle).
    var c4Enabled = true
    /// Encode in the official app's entry layout (CRC?, group, icon,
    /// priority, vibration, 0xC4) instead of GB's (CRC, group, priority,
    /// icon). Byte-verified against 0x0C00 dumps written by the official
    /// iOS app.
    var officialLayout = false

    init(packageName: String, iconName: String) {
        self.packageName = packageName
        var crc = Data()
        crc.appendUInt32LE(Checksums.crc32(Data(packageName.utf8)))
        self.packageCrc = crc
        self.iconName = iconName
    }

    init(packageName: String, packageCrc: Data, iconName: String) {
        self.packageName = packageName
        self.packageCrc = packageCrc
        self.iconName = iconName
    }

    /// The phone-call entry uses a firmware-known magic CRC and a fixed
    /// multi-icon config (incoming/missed call), GB-verbatim.
    static let call = AppNotificationFilter(packageName: "call",
                                            packageCrc: Data([0x80, 0x00, 0x59, 0xB7]),
                                            iconName: "icIncomingCall.icon")

    /// Fallback entry for notifications from apps that have no own filter.
    static func generic(iconName: String = "general_white.bin") -> AppNotificationFilter {
        AppNotificationFilter(packageName: "generic", iconName: iconName)
    }

    /// The official app's "all notifications" mechanism: an entry with NO
    /// package CRC matches every app (group 7, priority 0xFF, per the
    /// official dump). This is what lets arbitrary apps through on iOS.
    static func catchAll(iconName: String = "general_white.bin") -> AppNotificationFilter {
        var filter = AppNotificationFilter(packageName: "*", packageCrc: Data(),
                                           iconName: iconName)
        filter.groupId = 7
        filter.priority = 0xFF
        filter.officialLayout = true
        return filter
    }

    /// The firmware's ANCS key for a bundle id: CRC32 over the UTF-8 bytes
    /// **plus the NUL terminator**, little-endian.
    static func ancsCrc(_ bundleId: String) -> Data {
        var bytes = Data(bundleId.utf8)
        bytes.append(0)
        var crc = Data()
        crc.appendUInt32LE(Checksums.crc32(bytes))
        return crc
    }

    /// Per-app entry in the official layout — matches ANCS notifications
    /// from `bundleId` and shows them with `iconName`.
    static func app(bundleId: String, iconName: String) -> AppNotificationFilter {
        var filter = AppNotificationFilter(packageName: bundleId,
                                           packageCrc: ancsCrc(bundleId), iconName: iconName)
        filter.groupId = 2
        filter.priority = 0x00
        filter.officialLayout = true
        return filter
    }

    /// Actively blocks an app's notifications (official app's disable
    /// toggle): its CRC with an empty icon and 0xC4 = 0. Wins over the
    /// catch-all, whose priority (0xFF) is lower than this entry's 0x00.
    static func blocked(bundleId: String) -> AppNotificationFilter {
        var filter = AppNotificationFilter(packageName: bundleId,
                                           packageCrc: ancsCrc(bundleId), iconName: "")
        filter.groupId = 7
        filter.priority = 0x00
        filter.c4Enabled = false
        filter.officialLayout = true
        return filter
    }
}

/// Builds the NOTIFICATION_FILTER (0x0C00) file, byte-exact against
/// GB: NotificationFilterPutHRRequest.createFile.
enum NotificationFilterFile {
    private static let packageNameCrcId: UInt8 = 0x04
    private static let groupIdId: UInt8 = 0x80
    private static let priorityId: UInt8 = 0xC1
    private static let iconId: UInt8 = 0x82
    private static let vibrationId: UInt8 = 0xC3
    /// Enabled flag: 1 on every active official-app entry, 0 on blocked
    /// (user-disabled) apps.
    private static let enabledC4Id: UInt8 = 0xC4

    static func encode(_ configs: [AppNotificationFilter]) -> Data {
        var buffer = Data()
        for config in configs {
            if config.officialLayout {
                appendOfficialEntry(&buffer, config)
                continue
            }
            let iconBytes = config.iconName.utf8Prefix(maxBytes: 251)
            var payloadLength = config.iconName.isEmpty ? 12 : iconBytes.count + 18
            if config.packageName == "call" { payloadLength += 44 }
            buffer.appendUInt16LE(UInt16(payloadLength))

            buffer.append(contentsOf: [packageNameCrcId, 4])
            buffer.append(config.packageCrc)
            buffer.append(contentsOf: [groupIdId, 1, 0x00])
            buffer.append(contentsOf: [priorityId, 1, 0xFF])

            if config.packageName == "call" {
                // Fixed multi-icon config: incoming / missed / incoming.
                let incoming = "icIncomingCall.icon"
                let missed = "icMissedCall.icon"
                buffer.append(contentsOf: [iconId, UInt8(incoming.utf8.count + 4), 0x02, 0x00])
                buffer.append(UInt8(incoming.utf8.count + 1))
                buffer.append(Data(incoming.utf8))
                buffer.append(0x00)
                buffer.append(contentsOf: [0x40, 0x00])
                buffer.append(UInt8(missed.utf8.count + 1))
                buffer.append(Data(missed.utf8))
                buffer.append(0x00)
                buffer.append(contentsOf: [0xBD, 0x00])
                buffer.append(UInt8(incoming.utf8.count + 1))
                buffer.append(Data(incoming.utf8))
                buffer.append(0x00)
            } else if !config.iconName.isEmpty {
                buffer.append(contentsOf: [iconId, UInt8(iconBytes.count + 4), 0xFF, 0x00])
                buffer.append(UInt8(iconBytes.count + 1))
                buffer.append(iconBytes)
                buffer.append(0x00)
            }
        }
        return buffer
    }

    /// Official-app entry: [CRC (omitted on the catch-all)][group][icon]
    /// [priority][vibration 0 (apps only)][0xC4 = 1], u16 length prefix
    /// computed from the actual body. Byte-verified against the official
    /// iOS app's file for both the per-app and the catch-all shape.
    private static func appendOfficialEntry(_ buffer: inout Data, _ config: AppNotificationFilter) {
        var body = Data()
        if !config.packageCrc.isEmpty {
            body.append(contentsOf: [packageNameCrcId, 4])
            body.append(config.packageCrc)
        }
        body.append(contentsOf: [groupIdId, 1, config.groupId])
        let iconBytes = config.iconName.utf8Prefix(maxBytes: 251)
        body.append(contentsOf: [iconId, UInt8(iconBytes.count + 4), 0xFF, 0x00])
        body.append(UInt8(iconBytes.count + 1))
        body.append(iconBytes)
        body.append(0x00)
        body.append(contentsOf: [priorityId, 1, config.priority])
        if !config.packageCrc.isEmpty {
            body.append(contentsOf: [vibrationId, 1, 0x00])
        }
        body.append(contentsOf: [enabledC4Id, 1, config.c4Enabled ? 1 : 0])
        buffer.appendUInt16LE(UInt16(body.count))
        buffer.append(body)
    }

    /// Quiet-hours file: the generic entry only. The filter is a hard
    /// whitelist, so this drops every real ANCS notification (no bundle-id
    /// CRC matches "generic") while staying non-empty and keeping the
    /// app-generated test-notification path (which targets "generic")
    /// working.
    static func nightFilter() -> Data {
        encode([.generic()])
    }
}

/// Builds a NOTIFICATION_PLAY (0x0900) file — an app-generated notification
/// shown on the watch without going through ANCS
/// (GB: PlayNotificationRequest.createFile).
enum NotificationPlayFile {
    enum Kind: UInt8 {
        case incomingCall = 1
        case text = 2
        case notification = 3
        case email = 4
        case calendar = 5
        case missedCall = 6
        case dismiss = 7
    }

    static func encode(kind: Kind, flags: UInt8 = 0x02, packageName: String,
                       sender: String, message: String,
                       messageId: UInt32 = UInt32(Date().timeIntervalSince1970)) -> Data {
        encode(kind: kind, flags: flags,
               packageCrc: Checksums.crc32(Data(packageName.utf8)),
               title: packageName, sender: sender, message: message,
               messageId: messageId)
    }

    static func encode(kind: Kind, flags: UInt8, packageCrc: UInt32,
                       title: String, sender: String, message: String,
                       messageId: UInt32) -> Data {
        func bounded(_ value: String) -> Data {
            var data = value.utf8Prefix(maxBytes: 254)
            data.append(0)
            return data
        }
        let titleBytes = bounded(title)
        let senderBytes = bounded(sender)
        let messageBytes = bounded(message)

        var data = Data()
        let total = 10 + 4 + 4 + titleBytes.count + senderBytes.count + messageBytes.count
        data.appendUInt16LE(UInt16(total))
        data.append(10)                     // length-buffer length
        data.append(kind.rawValue)
        data.append(flags)
        data.append(4)                      // uid length
        data.append(4)                      // app bundle CRC length
        data.append(UInt8(titleBytes.count))
        data.append(UInt8(senderBytes.count))
        data.append(UInt8(messageBytes.count))
        data.appendUInt32LE(messageId)
        data.appendUInt32LE(packageCrc)
        data.append(titleBytes)
        data.append(senderBytes)
        data.append(messageBytes)
        return data
    }
}
