import Foundation

/// Button functions for the non-HR Q hybrids. Each carries a precompiled
/// firmware blob (header + payload, both copied verbatim from GB's
/// ConfigPayload enum — the payloads embed their own trailing CRCs) that is
/// packed into the SETTINGS_BUTTONS file (0x0600) by QButtonConfigFile.
enum QButtonFunction: String, CaseIterable, Codable {
    case forwardToPhone
    case forwardToPhoneMulti
    case musicControl
    case stopwatch
    case date
    case lastNotification
    case secondTimezone
    case volumeUp
    case volumeDown
    case stepGoalCompletion
    case ringPhone
    /// The official app's "alternate": each press cycles the small dial
    /// through alert / time 2 / alarm / date. One button, four registered
    /// payloads — decoded from settingsButtons_0600.bin (real Q Grant).
    case alternate

    var displayName: String {
        switch self {
        case .forwardToPhone: return String(localized: "Forward to phone")
        case .forwardToPhoneMulti: return String(localized: "Forward to phone (multi-press)")
        case .musicControl: return String(localized: "Music control")
        case .stopwatch: return String(localized: "Stopwatch")
        case .date: return String(localized: "Show date")
        case .lastNotification: return String(localized: "Show last notification")
        case .secondTimezone: return String(localized: "Second time zone")
        case .volumeUp: return String(localized: "Music volume up")
        case .volumeDown: return String(localized: "Music volume down")
        case .stepGoalCompletion: return String(localized: "Step goal progress")
        case .ringPhone: return String(localized: "Find my phone")
        case .alternate: return String(localized: "Alternate (cycle small dial)")
        }
    }

    /// One registered payload: the 4-byte header the button table points at
    /// plus the firmware blob it names.
    struct Entry: Equatable {
        let header: Data
        let blob: Data
    }

    /// Most functions register one payload; `alternate` registers the four
    /// sub-eye modes the watch cycles through (official order:
    /// alert, time 2, alarm, date).
    var entries: [Entry] {
        switch self {
        case .alternate:
            return [
                Entry(header: Self.hex("01021800"),
                      blob: Self.hex("010001021836000000010008000400000702010001011d00"
                                   + "89020104b0020089050107b00200b00200b00200"
                                   + "080150000100" + "9cf6efcd")),
                Entry(header: Self.hex("01021600"),
                      blob: Self.hex("010001021636000000010008000400000702020001011d00"
                                   + "89020104b0010089050107b00100b00100b00100"
                                   + "080150000100" + "c8b78887")),
                Entry(header: Self.hex("01021a00"),
                      blob: Self.hex("010001021a36000000010008000400000702000001011d00"
                                   + "89020104b0030089050107b00300b00300b00300"
                                   + "080150000100" + "a67957cc")),
                Entry(header: Self.hex("01021400"),
                      blob: Self.hex("01000102143400000001000600020000070001011d00"
                                   + "89020104b0000089050107b00000b00000b00000"
                                   + "080150000100" + "779c0c19")),
            ]
        default:
            return [Entry(header: header, blob: blob)]
        }
    }

    /// 4-byte header referenced from the file's button table. Note that
    /// forwardToPhone/ringPhone and forwardToPhoneMulti/musicControl share
    /// headers and payloads — the watch behaves identically; only the phone
    /// side treats their events differently (GB does the same).
    private var header: Data {
        switch self {
        case .forwardToPhone, .ringPhone: return Self.hex("01010c00")
        case .forwardToPhoneMulti, .musicControl: return Self.hex("01061200")
        case .stopwatch: return Self.hex("02012001")
        case .date: return Self.hex("01011400")
        case .lastNotification: return Self.hex("01011800")
        case .secondTimezone: return Self.hex("01011600")
        case .volumeUp: return Self.hex("01041200")
        // On-watch verified (Q Grant, physical press): 01051200 lowers the
        // volume, 01021c00 shows step-goal progress on the small dial —
        // GB's labels are correct.
        case .volumeDown: return Self.hex("01051200")
        case .stepGoalCompletion: return Self.hex("01021c00")
        case .alternate: fatalError("alternate is multi-entry — use entries")
        }
    }

    private var blob: Data {
        switch self {
        case .forwardToPhone, .ringPhone:
            return Self.hex("010001010c2e00000001000600010101"
                          + "030002010f008b000093000108011400"
                          + "0100fe08009300020100bfd554d1")
        case .forwardToPhoneMulti, .musicControl:
            return Self.hex("01000106126300000001000600010101"
                          + "030005011d008501f600008501420200"
                          + "8501430300850144040008011e000100"
                          + "020d008c01cd00019300010100030d00"
                          + "8c01b600019300010100040d008c01b5"
                          + "00019300010100fe080093000201007b"
                          + "564e97")
        case .stopwatch:
            return Self.hex("01000201202000000001010700030000"
                          + "0701000101080092000101000fc05f2a")
        case .date:
            return Self.hex("01000101142d00000001000600020000"
                          + "07000101160089050107b00000b00000"
                          + "b00000080150000100d089de6e")
        case .lastNotification:
            return Self.hex("01000101182f00000001000800040000"
                          + "070201000101160089050107b00200b0"
                          + "0200b002000801500001006b9d553a")
        case .secondTimezone:
            return Self.hex("01000101162f00000001000800040000"
                          + "070202000101160089050107b00100b0"
                          + "0100b001000801500001003d072801")
        case .volumeUp:
            return Self.hex("01000104125e00000001000600010101"
                          + "030005011d008501f600008501420200"
                          + "8501430300850148040008011e000100"
                          + "020d008c01e900019300010100030b00"
                          + "8c01e90000930001040a008c01000001"
                          + "0100fe08009300020100c6b2cbac")
        case .volumeDown:
            return Self.hex("01000105125e00000001000600010101"
                          + "030005011d008501f600008501420200"
                          + "8501430300850148040008011e000100"
                          + "020d008c01ea00019300010100030b00"
                          + "8c01ea0000930001040a008c01000001"
                          + "0100fe08009300020100fa184903")
        case .stepGoalCompletion:
            return Self.hex("010001021c3e00000001000600020000"
                          + "070001012700890501" + "07b00800b00800"
                          + "b008000801050089050107f10400f104"
                          + "00f104000801500001000bd9cfda")
        case .alternate:
            fatalError("alternate is multi-entry — use entries")
        }
    }

    private static func hex(_ string: String) -> Data {
        Data(hexString: string)!
    }
}

/// Packs button functions into the SETTINGS_BUTTONS (0x0600) file content.
/// Structure decoded byte-for-byte from a file written by the official iOS
/// app (settingsButtons_0600.bin, real Q Grant) — it extends GB's
/// ConfigFileBuilder format:
///   [01 00 00] version
///   [button count] then per button: [0x10/0x20/0x30][entry count]
///       and per entry [4-byte header][00]   (multi-entry = "alternate")
///   [payload count] + the distinct payload blobs
///   [customization count] + per payload [header][0A 00][01 02 01 00]
///   trailing CRC32 of everything before it.
enum QButtonConfigFile {
    /// `functions` in top/middle/bottom order.
    static func build(_ functions: [QButtonFunction]) -> Data {
        var buffer = Data([0x01, 0x00, 0x00])
        buffer.append(UInt8(functions.count))
        var buttonIndex: UInt8 = 0x00
        for function in functions {
            buttonIndex += 0x10
            buffer.append(buttonIndex)
            let entries = function.entries
            buffer.append(UInt8(entries.count))
            for entry in entries {
                buffer.append(entry.header)
                buffer.append(0x00)
            }
        }

        // One payload per registered id: a blob embeds its own header, so
        // blob equality covers the pair. (This also collapses musicControl +
        // forwardToPhoneMulti to one copy — same id, the watch couldn't tell
        // them apart anyway.)
        var distinct: [QButtonFunction.Entry] = []
        for function in functions {
            for entry in function.entries where !distinct.contains(entry) {
                distinct.append(entry)
            }
        }
        buffer.append(UInt8(distinct.count))
        for entry in distinct {
            buffer.append(entry.blob)
        }

        // Customization records, one per payload, exactly as the official
        // app writes them (GB omits the section — count 0 — which the watch
        // also accepts; we mirror the official file since it's our oracle).
        buffer.append(UInt8(distinct.count))
        for entry in distinct {
            buffer.append(entry.header)
            buffer.append(contentsOf: [0x0A, 0x00, 0x01, 0x02, 0x01, 0x00])
        }

        buffer.appendUInt32LE(Checksums.crc32(buffer))
        return buffer
    }
}
