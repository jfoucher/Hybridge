import Foundation

/// Configuration file items (TLV: [id u16][size u8][payload]), uploaded
/// encrypted to handle 0x0800.
enum ConfigItem {
    case time(epochSeconds: UInt32, millis: UInt16, offsetMinutes: Int16)
    case dailyStepGoal(UInt32)
    /// GB: CurrentStepCountConfigItem — written on the non-HR Q watches to
    /// drive the activity sub-dial (progress = steps / goal).
    case currentStepCount(UInt32)
    case vibrationStrength(UInt8)
    case units(UInt32)
    /// fromHour/fromMin, untilHour/untilMin, threshold minutes, enabled.
    case inactivityWarning(from: (UInt8, UInt8), until: (UInt8, UInt8), minutes: UInt8, enabled: Bool)
    /// Workout auto-detection for Running/Biking/Walking/Rowing.
    case fitnessDetection(WorkoutDetectionSettings)
    /// GB: HeartRateMeasurementModeItem. GB only ever reads this back; the
    /// write values (0 = off, -1 = automatic) are observed, not GB-verified.
    case heartRateMode(Int8)
    /// Second-timezone offset in minutes (GB: TimezoneOffsetConfigItem).
    case timezoneOffset(Int16)
    /// Body profile (config 0x0001, not in GB): the raw 7-byte value with
    /// height/weight patched in place — carried whole so the unknown bytes 0–1
    /// and 6 (likely age/gender/birth-year) survive a read-modify-write. See
    /// `WatchConfiguration.heightCm`/`weightKg` for the field layout.
    case bodyProfile(Data)

    var id: UInt16 {
        switch self {
        case .time: return 0x0C
        case .dailyStepGoal: return 0x03
        case .currentStepCount: return 0x02
        case .vibrationStrength: return 0x0A
        case .units: return 0x10
        case .inactivityWarning: return 0x09
        case .fitnessDetection: return 0x14
        case .heartRateMode: return 0x0E
        case .timezoneOffset: return 0x11
        case .bodyProfile: return 0x0001
        }
    }

    var payload: Data {
        var data = Data()
        switch self {
        case .time(let epoch, let millis, let offset):
            data.appendUInt32LE(epoch)
            data.appendUInt16LE(millis)
            data.appendInt16LE(offset)
        case .dailyStepGoal(let goal):
            data.appendUInt32LE(goal)
        case .currentStepCount(let steps):
            data.appendUInt32LE(steps)
        case .vibrationStrength(let strength):
            data.append(strength)
        case .units(let units):
            data.appendUInt32LE(units)
        case .inactivityWarning(let from, let until, let minutes, let enabled):
            data.append(contentsOf: [from.0, from.1, until.0, until.1, minutes, enabled ? 1 : 0])
        case .fitnessDetection(let settings):
            data = settings.payload
        case .heartRateMode(let mode):
            data.append(UInt8(bitPattern: mode))
        case .timezoneOffset(let minutes):
            data.appendInt16LE(minutes)
        case .bodyProfile(let raw):
            data = raw
        }
        return data
    }

    /// Gender codes stored in body-profile byte 1 (verified by A→B→A capture
    /// against the official iOS app).
    enum Gender: Int { case nonBinary = 0, male = 1, female = 2 }

    /// Rewrites the body-profile fields, preserving every other byte (byte 6 is
    /// unknown and always 0). `base` is the item read back from the watch; when
    /// absent an all-zero template is used. Layout: `[age years u8][gender u8]
    /// [height cm u16 LE][weight kg u16 LE][0x00]`.
    static func bodyProfile(base: Data?, ageYears: Int, gender: Gender,
                            heightCm: Int, weightKg: Int) -> ConfigItem {
        var bytes = base.map(Array.init) ?? [0, 0, 0, 0, 0, 0, 0]
        if bytes.count < 7 { bytes += Array(repeating: 0, count: 7 - bytes.count) }
        bytes[0] = UInt8(clamping: ageYears)
        bytes[1] = UInt8(gender.rawValue)
        bytes[2] = UInt8(heightCm & 0xFF)
        bytes[3] = UInt8((heightCm >> 8) & 0xFF)
        bytes[4] = UInt8(weightKg & 0xFF)
        bytes[5] = UInt8((weightKg >> 8) & 0xFF)
        return .bodyProfile(Data(bytes))
    }

    static func currentTime(date: Date = Date(), timeZone: TimeZone = .current) -> ConfigItem {
        let millis = date.timeIntervalSince1970
        let epoch = UInt32(millis)
        let ms = UInt16((millis - Double(epoch)) * 1000)
        let offsetMinutes = Int16(timeZone.secondsFromGMT(for: date) / 60)
        return .time(epochSeconds: epoch, millis: ms, offsetMinutes: offsetMinutes)
    }

    static func encodeFile(_ items: [ConfigItem]) -> Data {
        var data = Data()
        for item in items {
            let payload = item.payload
            data.appendUInt16LE(item.id)
            data.append(UInt8(payload.count))
            data.append(payload)
        }
        return data
    }
}

/// Values read back from the watch's configuration file (TLV items).
struct WatchConfiguration {
    var batteryPercentage: Int?
    var batteryVoltageMV: Int?
    var currentStepCount: Int?
    var dailyStepGoal: Int?
    var vibrationStrength: Int?
    var heartRateMode: Int8?
    var timezoneOffsetMinutes: Int16?
    /// Body profile (item 0x0001): raw value plus the decoded fields.
    /// `bodyProfileRaw` is kept so a write can preserve the unknown bytes.
    var bodyProfileRaw: Data?
    var ageYears: Int?
    var gender: Int?
    var heightCm: Int?
    var weightKg: Int?

    /// Parses config-file content (12-byte header and trailing CRC removed).
    static func parse(_ data: Data) -> WatchConfiguration {
        var config = WatchConfiguration()
        var offset = 0
        while data.count - offset >= 3 {
            let id = data.u16LE(at: offset)
            let length = Int(data.u8(at: offset + 2))
            offset += 3
            guard data.count - offset >= length else { break }
            let payload = data.slice(offset, length)
            switch id {
            case 0x0001 where length >= 6:
                config.bodyProfileRaw = payload
                config.ageYears = Int(payload.u8(at: 0))
                config.gender = Int(payload.u8(at: 1))
                config.heightCm = Int(payload.u16LE(at: 2))
                config.weightKg = Int(payload.u16LE(at: 4))
            case 0x0D where length >= 3:
                config.batteryVoltageMV = Int(payload.u16LE(at: 0))
                config.batteryPercentage = Int(payload.u8(at: 2))
            case 0x02 where length >= 4:
                config.currentStepCount = Int(payload.u32LE(at: 0))
            case 0x03 where length >= 4:
                config.dailyStepGoal = Int(payload.u32LE(at: 0))
            case 0x0A where length >= 1:
                config.vibrationStrength = Int(payload.u8(at: 0))
            case 0x0E where length >= 1:
                config.heartRateMode = Int8(bitPattern: payload.u8(at: 0))
            case 0x11 where length >= 2:
                config.timezoneOffsetMinutes = Int16(bitPattern: payload.u16LE(at: 0))
            default:
                break
            }
            offset += length
        }
        return config
    }
}

/// Workout auto-detection settings (config item 0x14). Template bytes and
/// offsets are the firmware's format — 4 blocks of 6 bytes
/// (Running/Biking/Walking/Rowing), the item declaring 30 bytes so the last 6
/// are zero padding.
struct WorkoutDetectionSettings: Codable, Equatable {
    struct Activity: Codable, Equatable {
        var recognize = false
        var askFirst = true
        var minutes: Int
    }

    var running = Activity(minutes: 3)
    var biking = Activity(minutes: 5)
    var walking = Activity(minutes: 10)
    var rowing = Activity(minutes: 3)

    var payload: Data {
        var data = Data([
            0x01, 0x00, 0x03, 0x01, 0x01, 0x05,   // Running
            0x02, 0x00, 0x05, 0x01, 0x01, 0x01,   // Biking
            0x08, 0x00, 0x0A, 0x01, 0x01, 0x05,   // Walking
            0x09, 0x00, 0x03, 0x01, 0x01, 0x01,   // Rowing
        ])
        func apply(_ activity: Activity, flagsAt flagIndex: Int) {
            guard activity.recognize else { return }
            data[flagIndex] |= 0x01
            if activity.askFirst { data[flagIndex] |= 0x02 }
            data[flagIndex + 1] = UInt8(activity.minutes & 0xFF)
        }
        apply(running, flagsAt: 1)
        apply(biking, flagsAt: 7)
        apply(walking, flagsAt: 13)
        apply(rowing, flagsAt: 19)
        data.append(Data(count: 6))    // item size is 30, content is 24
        return data
    }
}

/// One alarm slot. 
struct WatchAlarm: Codable, Identifiable, Equatable {
    var id = UUID()
    var hour: Int
    var minute: Int
    /// Bitmask using Self.dayBit indices; empty mask + repeats=false = one-shot.
    var daysMask: UInt8
    var repeats: Bool
    var label: String
    var enabled: Bool = true

    /// Order matters: Sunday=0, Monday=1, Tuesday=2, THURSDAY=3, WEDNESDAY=4,
    /// Friday=5, Saturday=6 - the firmware's alarm weekday bit order
    static var dayNames: [String] {
        let names = DateFormatter().shortWeekdaySymbols ??
            ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return [names[0], names[1], names[2], names[4], names[3], names[5], names[6]]
    }

    var timeCore: Data {
        let first: UInt8 = repeats ? (0x80 | daysMask) : 0xFF
        var second = UInt8(minute)
        if repeats { second |= 0x80 }
        return Data([first, second, UInt8(hour)])
    }

    /// TLV alarm file (file format 0x03) for all given alarms.
    static func encodeFile(_ alarms: [WatchAlarm]) -> Data {
        var data = Data()
        for alarm in alarms where alarm.enabled {
            var label = alarm.label.isEmpty ? "---" : alarm.label
            label = String(label.prefix(15))
            let message = "---"
            let labelBytes = label.data(using: .utf8) ?? Data()
            let messageBytes = message.data(using: .utf8) ?? Data()
            let alarmSize = 17 + labelBytes.count + messageBytes.count

            data.append(0x00)
            data.appendUInt16LE(UInt16(alarmSize - 3))
            data.append(0x00)                       // sub-entry: time
            data.appendUInt16LE(3)
            data.append(alarm.timeCore)
            data.append(0x01)                       // sub-entry: label
            data.appendUInt16LE(UInt16(labelBytes.count + 1))
            data.append(labelBytes)
            data.append(0x00)
            data.append(0x02)                       // sub-entry: message
            data.appendUInt16LE(UInt16(messageBytes.count + 1))
            data.append(messageBytes)
            data.append(0x00)
        }
        return data
    }

    /// Legacy 3-bytes-per-alarm format (used when the negotiated alarm file
    /// version is not 3).
    static func encodeLegacyFile(_ alarms: [WatchAlarm]) -> Data {
        var data = Data()
        for alarm in alarms where alarm.enabled {
            data.append(alarm.timeCore)
        }
        return data
    }

    /// Decodes a 3-byte time core (inverse of `timeCore`; repeat flag lives in
    /// bit 7 of the minute byte, matching GB's Alarm.fromBytes).
    private static func fromTimeCore(_ bytes: Data, label: String) -> WatchAlarm {
        let repeats = bytes.u8(at: 1) & 0x80 != 0
        return WatchAlarm(hour: Int(bytes.u8(at: 2)),
                          minute: Int(bytes.u8(at: 1) & 0x7F),
                          daysMask: repeats ? bytes.u8(at: 0) & 0x7F : 0,
                          repeats: repeats,
                          label: label)
    }

    /// Parses the alarm file read back from the watch (content only, header
    /// and CRC removed). Version 3 is the TLV format `encodeFile` writes; any
    /// other version is the legacy 3-bytes-per-alarm layout
    /// (GB: AlarmsGetRequest, which only knows the legacy one).
    static func parseFile(_ data: Data, version: UInt16) -> [WatchAlarm] {
        var alarms: [WatchAlarm] = []
        if version == 0x03 {
            var offset = 0
            while data.count - offset >= 3 {
                guard data.u8(at: offset) == 0x00 else { break }
                let entrySize = Int(data.u16LE(at: offset + 1))
                offset += 3
                guard data.count - offset >= entrySize else { break }
                var cursor = offset
                var timeCore: Data?
                var label = ""
                while cursor + 3 <= offset + entrySize {
                    let type = data.u8(at: cursor)
                    let length = Int(data.u16LE(at: cursor + 1))
                    cursor += 3
                    guard cursor + length <= offset + entrySize else { break }
                    switch type {
                    case 0x00 where length >= 3:
                        timeCore = data.slice(cursor, 3)
                    case 0x01 where length >= 1:
                        label = String(data: data.slice(cursor, length - 1), encoding: .utf8) ?? ""
                    default:
                        break   // 0x02 message — not shown in the UI
                    }
                    cursor += length
                }
                if let timeCore {
                    alarms.append(fromTimeCore(timeCore, label: label == "---" ? "" : label))
                }
                offset += entrySize
            }
        } else {
            var offset = 0
            while data.count - offset >= 3 {
                alarms.append(fromTimeCore(data.slice(offset, 3), label: ""))
                offset += 3
            }
        }
        return alarms
    }
}

/// An app or watchface installed on the watch, parsed from the APP_CODE file.
struct InstalledApp: Identifiable, Equatable {
    var name: String
    var version: String
    var handle: UInt8

    var id: String { name }
    var isWatchface: Bool { !name.hasSuffix("App") }
    /// Handle used to delete this app.
    var fullHandle: UInt16 { (UInt16(0x15) << 8) | UInt16(handle) }

    /// Whether a newer build of this app/watchface exists (GB flags apps below
    /// KNOWN_WAPP_VERSIONS and watchfaces not built with the current
    /// watchface version). nil = no reference version known.
    var isOutdated: Bool? {
        if isWatchface {
            // Only faces we can rebuild ourselves count; imported ones just
            // differ, which doesn't mean an update exists.
            return version == KnownAppVersions.watchface ? false : nil
        }
        guard let known = KnownAppVersions.apps[name] else { return nil }
        return Self.compare(version, isOlderThan: known)
    }

    static func compare(_ version: String, isOlderThan reference: String) -> Bool {
        let lhs = version.split(separator: ".").compactMap { Int($0) }
        let rhs = reference.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// Parses the raw APP_CODE file (12-byte header still present; entries
    /// until fewer than 4 bytes + trailing CRC remain).
    static func parseList(fromRawFile fileData: Data) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var offset = 12
        while fileData.count - offset > 4 {
            guard fileData.count - offset >= 4 else { break }
            _ = fileData.u16LE(at: offset)          // packet length
            let nameLength = Int(fileData.u8(at: offset + 3)) - 1
            guard nameLength > 0, fileData.count - offset >= 4 + nameLength + 9 else { break }
            let name = String(data: fileData.slice(offset + 4, nameLength), encoding: .utf8) ?? "?"
            var cursor = offset + 4 + nameLength + 1  // skip null byte
            let handle = fileData.u8(at: cursor)
            cursor += 1
            cursor += 4                               // hash
            let versionMajor = fileData.u8(at: cursor)
            let versionMinor = fileData.u8(at: cursor + 1)
            cursor += 2
            cursor += 2                               // unknown
            apps.append(InstalledApp(name: name,
                                     version: "\(versionMajor).\(versionMinor)",
                                     handle: handle))
            offset = cursor
        }
        return apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

/// Parses the DEVICE_INFO file (TLV records); record 0x0A maps each major
/// file handle to the file version the firmware expects.
struct DeviceFileVersions {
    private var versions: [UInt8: UInt16] = [:]

    init() {}

    init(deviceInfoFile: Data) {
        var offset = 0
        while deviceInfoFile.count - offset >= 3 {
            let type = deviceInfoFile.u16LE(at: offset)
            let length = Int(deviceInfoFile.u8(at: offset + 2))
            offset += 3
            guard deviceInfoFile.count - offset >= length else { break }
            if type == 0x0A {
                var cursor = offset
                while cursor + 3 <= offset + length {
                    versions[deviceInfoFile.u8(at: cursor)] = deviceInfoFile.u16LE(at: cursor + 1)
                    cursor += 3
                }
            }
            offset += length
        }
        // Some fixed additions
        versions[0x13] = 0x0002
        versions[0x15] = 0x0003
    }

    func version(for handle: FossilFileHandle) -> UInt16 {
        versions[handle.major] ?? 0
    }

    var isEmpty: Bool { versions.isEmpty }

    /// Loggable "major=version" table, sorted by handle.
    var summary: String {
        versions.sorted { $0.key < $1.key }
            .map { String(format: "%02X=%d", $0.key, $0.value) }
            .joined(separator: " ")
    }
}

/// The three physical buttons on the Hybrid HR (top/middle/bottom crown).
enum WatchButton: String, CaseIterable, Codable {
    case top, middle, bottom
}

/// Short (single press) vs long (hold) press.
enum ButtonPress: String, CaseIterable, Codable {
    case short, long
}

/// One resolved button→app mapping as sent in `master._.config.buttons`.
/// `event` is the firmware event string (e.g. "top_short_press_release").
struct ButtonAssignment: Equatable {
    let event: String
    let appName: String
}

/// A user's button choice before firmware-specific event strings are resolved.
struct ButtonSelection: Equatable, Codable {
    var button: WatchButton
    var press: ButtonPress
    var appName: String

    var slotKey: String { "\(button.rawValue)_\(press.rawValue)" }
}

/// Firmware-aware resolution of button selections into wire assignments.
enum ButtonConfig {
    /// always send all the slots at once
    static let slots: [(button: WatchButton, press: ButtonPress, defaultApp: String)] = [
        (.top, .short, "weatherApp"),
        (.top, .long, "weatherApp"),
        (.middle, .short, "launcherApp"),
        (.middle, .long, "launcherApp"),
        (.bottom, .short, "musicApp"),
        (.bottom, .long, "musicApp"),
    ]

    /// Default selection shown in the UI on first launch.
    static var defaults: [ButtonSelection] {
        slots.map { ButtonSelection(button: $0.button, press: $0.press, appName: $0.defaultApp) }
    }

    /// Apps that are always assignable even if they don't appear in the app
    /// directory — `workoutApp` lives in firmware (GB exempts only this one).
    static let alwaysAvailable: Set<String> = ["workoutApp"]

    /// Builds the complete `master._.config.buttons` array GB-style: every slot
    /// resolved to the user's pick (or its default), gated by firmware, and
    /// dropped only when its app isn't installed. `installed` is the set of app
    /// names currently on the watch. `firmware` only gates `middle_hold`; short
    /// presses emit both event names (see `events`).
    static func assignments(userSelections: [ButtonSelection],
                            installed: Set<String>,
                            firmware: FirmwareVersion?) -> [ButtonAssignment] {
        let allowMiddleHold = firmware?.atLeast(3, 0) ?? true
        let available = installed.union(alwaysAvailable)

        var picks: [String: String] = [:]
        for selection in userSelections where !selection.appName.isEmpty {
            picks[selection.slotKey] = selection.appName
        }

        var result: [ButtonAssignment] = []
        for slot in slots {
            if slot.button == .middle, slot.press == .long, !allowMiddleHold { continue }
            let key = "\(slot.button.rawValue)_\(slot.press.rawValue)"
            let app = picks[key] ?? slot.defaultApp
            // Never send a name the watch doesn't know: an unknown app in the
            // config leaves that button dead (and may reject the whole push).
            guard available.contains(app) else { continue }
            for evt in events(slot.button, slot.press) {
                result.append(ButtonAssignment(event: evt, appName: app))
            }
        }
        return result
    }

    /// The set of every app name referenced by a button assignment — the set a
    /// watch switch needs re-uploaded if missing, so a global button config
    /// keeps working on a watch that never had the app installed. Built-in apps
    /// (weatherApp, musicApp…) fall out naturally: they're never uploaded, so
    /// never cached, so intersecting this set against the on-disk cache excludes
    /// them without needing to special-case them here.
    static func referencedAppNames(buttonSelections: [ButtonSelection]) -> Set<String> {
        Set(buttonSelections.map(\.appName).filter { !$0.isEmpty })
    }

    /// Firmware event strings for a button/press. Short presses emit BOTH the
    /// modern ("short_press_release", FW ≥ 2.19) and legacy ("single_click", FW
    /// < 2.19) names — the watch only ever fires the one its firmware knows, so
    /// sending both makes the mapping work without detecting the version. Long
    /// press is always "<button>_hold".
    static func events(_ button: WatchButton, _ press: ButtonPress) -> [String] {
        switch press {
        case .long: return ["\(button.rawValue)_hold"]
        case .short: return ["\(button.rawValue)_short_press_release", "\(button.rawValue)_single_click"]
        }
    }
}

/// Best-effort parse of the firmware revision string (e.g. "DN1.0.2.20") into
/// a comparable major.minor pair. Mirrors GB's own extraction exactly (regex
/// `(?<=[A-Z]{2}[0-9]\.[0-9]\.)[0-9]+\.[0-9]+` on the 2A26 string): anchor on
/// the fixed "XX#.#." prefix and take the major.minor immediately after it.
/// A "last two dotted numbers in the whole string" heuristic looked
/// equivalent but silently breaks on real firmware strings with a trailing
/// suffix (e.g. "DN1.0.2.20r.v5", see WatchKindTests) — the extra digit
/// after the suffix gets picked up as "minor" instead of the real one.
struct FirmwareVersion {
    let major: Int
    let minor: Int

    init?(_ string: String?) {
        guard let string else { return nil }
        let chars = Array(string)
        var i = 0
        while i + 6 <= chars.count {
            guard chars[i].isUppercase, chars[i + 1].isUppercase,
                  chars[i + 2].isNumber, chars[i + 3] == ".",
                  chars[i + 4].isNumber, chars[i + 5] == "." else {
                i += 1
                continue
            }
            let rest = string[string.index(string.startIndex, offsetBy: i + 6)...]
            let parts = rest.prefix(while: { $0.isNumber || $0 == "." })
                .split(separator: ".")
                .compactMap { Int($0) }
            if parts.count >= 2 {
                major = parts[0]
                minor = parts[1]
                return
            }
            i += 1
        }
        return nil
    }

    func atLeast(_ major: Int, _ minor: Int) -> Bool {
        self.major != major ? self.major > major : self.minor >= minor
    }
}

enum JsonPayloads {
    /// {"push":{"set":{key: value}}}
    static func pushSet(key: String, value: Any) -> Data {
        pushSet(values: [key: value])
    }

    /// {"push":{"set":{...}}} with several keys in one push.
    static func pushSet(values: [String: Any]) -> Data {
        let object: [String: Any] = ["push": ["set": values]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Text for a custom-text widget on the active face (the widgetCustom
    /// blob reads upper_text/lower_text from its config).
    static func customWidgetText(index: Int, upper: String, lower: String) -> Data {
        pushSet(values: [
            "widgetCustom\(index)._.config.upper_text": upper,
            "widgetCustom\(index)._.config.lower_text": lower,
        ])
    }

    static func selectTheme(_ watchfaceName: String) -> Data {
        pushSet(key: "themeApp._.config.selected_theme", value: watchfaceName)
    }

    /// Launches an installed app on the watch (GB: startAppOnWatch). The key
    /// lives on the active face's config, so it only works while a
    /// customWatchFace-based face is shown.
    static func startApp(_ appName: String) -> Data {
        pushSet(key: "customWatchFace._.config.start_app", value: appName)
    }

    // MARK: - Buttons (GB: ButtonConfigurationPutRequest)

    /// {"push":{"set":{"master._.config.buttons":[{"button_evt":…,"name":…}]}}}
    static func buttonConfig(_ assignments: [ButtonAssignment]) -> Data {
        pushSet(key: "master._.config.buttons",
                value: assignments.map { ["button_evt": $0.event, "name": $0.appName] })
    }

    /// {"res":{"id":id,"set":{...}}} — a reply correlated to a watch request.
    static func res(id: Int, set: [String: Any]) -> Data {
        let object: [String: Any] = ["res": ["id": id, "set": set]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// {"res":{"set":{...}}} — an uncorrelated push (no matching req id).
    static func res(set: [String: Any]) -> Data {
        let object: [String: Any] = ["res": ["set": set]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: - Home Assistant app

    /// Correlated response consumed from homeAssistantApp._.config.response.
    /// `id` belongs to the Fossil req/res transport; `token` belongs to the
    /// watch app and prevents a late network answer completing a newer view.
    static func homeAssistantResponse(id: Int, token: Int64, status: String,
                                      entities: [HomeAssistantEntity] = [],
                                      message: String? = nil) -> Data {
        var value: [String: Any] = ["token": token, "status": status]
        if status == "ok" { value["entities"] = entities.map(\.watchDictionary) }
        if let message { value["message"] = message }
        return res(id: id, set: ["homeAssistantApp._.config.response": value])
    }

    private static func alive(inSeconds seconds: Int, now: Date = Date()) -> Int {
        Int(now.timeIntervalSince1970) + seconds
    }

    // MARK: - Weather (GB: FossilHRWatchAdapter.java:1507-1660, 2011-2035)

    /// Watchface widget payload (`weatherInfo`). `id` doesn't matter to the
    /// watch but is echoed for correlation. `rain`/`uv` are extra fields the
    /// stock weatherInfo complication never reads (it only uses alive/unit/
    /// temp/cond_id) — added so the custom watchface's `rain`/`uv` dynamic
    /// text sources can piggyback on this same bare, globally-`get_common()`-
    /// visible key instead of the per-node `widgetChanceOfRain._.config.info`/
    /// `widgetUV._.config.info` paths those stock complications use, which
    /// only a node literally named that way can ever read.
    static func weatherInfoResponse(id: Int, snapshot: WeatherSnapshot, now: Date = Date()) -> Data {
        let value: [String: Any] = [
            "alive": alive(inSeconds: 3600, now: now),
            "unit": snapshot.unit,
            "temp": snapshot.temp,
            "cond_id": snapshot.condId,
            "rain": snapshot.rain,
            "uv": snapshot.uv,
        ]
        return res(id: id, set: ["weatherInfo": value])
    }

    /// weatherApp full-location payload, including 3h/3-day forecasts.
    static func weatherAppResponse(id: Int, snapshot: WeatherSnapshot, now: Date = Date()) -> Data {
        let location: [String: Any] = [
            "alive": alive(inSeconds: 3600, now: now),
            "city": snapshot.city,
            "unit": snapshot.unit,
            "temp": snapshot.temp,
            "high": snapshot.high,
            "low": snapshot.low,
            "rain": snapshot.rain,
            "uv": snapshot.uv,
            "message": snapshot.message,
            "cond_id": snapshot.condId,
            "forecast_day": snapshot.forecastDay.map {
                ["hour": $0.hour, "cond_id": $0.condId, "temp": $0.temp] as [String: Any]
            },
            "forecast_week": snapshot.forecastWeek.map {
                ["day": $0.day, "cond_id": $0.condId, "high": $0.high, "low": $0.low] as [String: Any]
            },
        ]
        return res(id: id, set: ["weatherApp._.config.locations": [location]])
    }

    /// Rain-chance widget. Fire-and-forget, no `id`.
    static func rainWidgetResponse(rainPercent: Int, now: Date = Date()) -> Data {
        res(set: ["widgetChanceOfRain._.config.info": ["alive": alive(inSeconds: 900, now: now), "rain": rainPercent]])
    }

    /// UV widget. Fire-and-forget, no `id`.
    static func uvWidgetResponse(uv: Int, now: Date = Date()) -> Data {
        res(set: ["widgetUV._.config.info": ["alive": alive(inSeconds: 900, now: now), "uv": uv]])
    }

    // MARK: - Calendar (GB: FossilHRWatchAdapter.java:1642-1715)

    /// Single fire-and-forget push, no `id`. `appName` is the watch app whose
    /// config the events are attached to (stock watchfaces read `customWatchFace`).
    static func calendarEventsPush(_ events: [CalendarEventPayload], appName: String = "customWatchFace") -> Data {
        let items = events.map { event -> [String: Any] in
            [
                "id": event.id,
                "title": event.title,
                "desc": event.desc,
                "start": event.start,
                "end": event.end,
                "reminders": event.reminders,
            ]
        }
        return res(set: ["\(appName)._.config.events": items])
    }
}

/// On-watch UI string replacements (GB: TranslationsPutRequest, cooked put
/// to ASSET_TRANSLATIONS 0x0702). Payload: locale (e.g. "de_DE") + NUL, then
/// per item [u16LE origLen+1][original][0][u16LE transLen+1][translated][0].
struct TranslationData: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id = UUID()
        var original: String
        var translated: String
    }

    /// 5-character locale like "de_DE" (the firmware expects exactly that shape).
    var locale: String
    var items: [Item]

    func encode() -> Data {
        var data = Data()
        data.append(Data(locale.utf8))
        data.append(0x00)
        for item in items {
            let original = Data(item.original.utf8)
            let translated = Data(item.translated.utf8)
            data.appendUInt16LE(UInt16(original.count + 1))
            data.append(original)
            data.append(0x00)
            data.appendUInt16LE(UInt16(translated.count + 1))
            data.append(translated)
            data.append(0x00)
        }
        return data
    }
}

/// A single WeatherKit fetch, already converted to the watch's units and
/// icon table. Built by WeatherProvider; kept WeatherKit-free here so the
/// JSON shape can be unit-tested without network/location access.
struct WeatherSnapshot {
    struct HourPoint { var hour: Int; var condId: Int; var temp: Int }
    struct DayPoint { var day: String; var condId: Int; var high: Int; var low: Int }

    var unit: String              // "c" or "f"
    var city: String
    var temp: Int
    var high: Int
    var low: Int
    var rain: Int                 // precipitation chance, percent
    var uv: Int
    var message: String           // condition text
    var condId: Int
    var forecastDay: [HourPoint]  // next 3 hours
    var forecastWeek: [DayPoint]  // next 3 days
}

/// One calendar entry as pushed to `customWatchFace._.config.events`.
struct CalendarEventPayload {
    var id: Int64
    var title: String
    var desc: String
    var start: Int
    var end: Int
    var reminders: [Int]
}
