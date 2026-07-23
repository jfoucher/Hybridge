import Foundation
@preconcurrency import CoreBluetooth

enum FossilUUID {
    static let service = CBUUID(string: "3DDA0001-957F-7D4A-34A6-74696673696D")
    /// Basic command channel.
    static let char0002 = CBUUID(string: "3DDA0002-957F-7D4A-34A6-74696673696D")
    /// File transfer control (requests + response opcodes).
    static let char0003 = CBUUID(string: "3DDA0003-957F-7D4A-34A6-74696673696D")
    /// File transfer data (chunked payload).
    static let char0004 = CBUUID(string: "3DDA0004-957F-7D4A-34A6-74696673696D")
    /// Authentication.
    static let char0005 = CBUUID(string: "3DDA0005-957F-7D4A-34A6-74696673696D")
    /// Asynchronous events from the watch (buttons, JSON requests).
    static let char0006 = CBUUID(string: "3DDA0006-957F-7D4A-34A6-74696673696D")
    static let char0007 = CBUUID(string: "3DDA0007-957F-7D4A-34A6-74696673696D")

    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    static let deviceInfoService = CBUUID(string: "180A")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let modelNumber = CBUUID(string: "2A24")
    static let heartRateMeasurement = CBUUID(string: "2A37")

    static let vendorNotifyChars: [CBUUID] = [char0002, char0003, char0004, char0005, char0006, char0007]
}

/// Hard ceiling on the size of a file we will accept from the watch.
///
/// The declared size in a file-get status frame is attacker-controlled: the
/// discovery filter matches on advertised name/service UUID, both of which any
/// nearby device can claim, and the Q family runs the file protocol with no
/// crypto at all. Without a clamp, a declared 4 GiB pre-allocates the buffer
/// and the app is jetsammed. The largest real file is the OTA firmware image
/// (a few hundred KB), so 4 MiB leaves ample headroom.
let fossilMaxFileSize = 4 * 1024 * 1024

/// 16-bit file handles ((major << 8) | minor), written little-endian on the wire.
enum FossilFileHandle: UInt16, CaseIterable {
    case otaFile = 0x00FF
    case activity = 0x0100
    case hardwareLog = 0x0200
    case font = 0x0300
    case uiControl = 0x0500
    case settingsButtons = 0x0600
    case assetBackgroundImages = 0x0700
    case assetNotificationImages = 0x0701
    case assetTranslations = 0x0702
    case assetReplyImages = 0x0703
    case configuration = 0x0800
    case notificationPlay = 0x0900
    case alarms = 0x0A00
    case deviceInfo = 0x0B00
    case notificationFilter = 0x0C00
    case watchParameters = 0x0E00
    case lookupTable = 0x0F00
    case rate = 0x1000
    case replyMessages = 0x1300
    case appCode = 0x15FE

    var major: UInt8 { UInt8((rawValue >> 8) & 0xFF) }
    var minor: UInt8 { UInt8(rawValue & 0xFF) }
}

/// Latest app/watchface versions.
/// Installed apps older than these are flagged as out of date.
enum KnownAppVersions {
    static let watchface = "1.14"

    static let apps: [String: String] = [
        "buddyChallengeApp": "2.10",
        "commuteApp": "2.5",
        "launcherApp": "3.9",
        "musicApp": "3.13",
        "notificationsPanelApp": "3.7",
        "ringPhoneApp": "3.8",
        "settingApp": "3.13",
        "stopwatchApp": "3.8",
        "timerApp": "3.9",
        "weatherApp": "3.11",
        "wellnessApp": "3.16",
        "AlexaApp": "3.11",
    ]
}

enum FossilResultCode {
    static func describe(_ code: UInt8) -> String {
        switch code {
        case 0: return String(localized: "success")
        case 1: return String(localized: "invalid operation data")
        case 2: return String(localized: "operation in progress")
        case 3: return String(localized: "missed packet")
        case 4: return String(localized: "socket busy")
        case 5: return String(localized: "verification failed")
        case 6: return String(localized: "overflow")
        case 7: return String(localized: "size over limit")
        // 128+: firmware-internal errors (GB ResultCode)
        case 128: return String(localized: "firmware internal error")
        case 129: return String(localized: "file not open")
        case 130: return String(localized: "file access error")
        case 131: return String(localized: "file not found")
        case 132: return String(localized: "file not valid")
        case 133: return String(localized: "file already exists")
        case 134: return String(localized: "not enough memory on watch")
        case 135: return String(localized: "not implemented")
        case 136: return String(localized: "not supported")
        case 137: return String(localized: "socket busy")
        case 138: return String(localized: "socket already open")
        case 139: return String(localized: "input data invalid")
        case 140: return String(localized: "not authenticated")
        case 141: return String(localized: "size over limit")
        default: return String(localized: "error \(code)")
        }
    }

    static func isSuccess(_ code: UInt8) -> Bool { code == 0 }
}

enum FossilError: LocalizedError {
    case notConnected
    case missingCharacteristic
    case timeout(String)
    case unexpectedResponse(String)
    case resultCode(UInt8, context: String)
    case crcMismatch(String)
    case authenticationFailed(String)
    case missingAuthKey
    case notAuthenticated
    case sessionNotHeld(String)
    case staleConnection
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "Watch is not connected")
        case .missingCharacteristic: return String(localized: "Bluetooth characteristic not found")
        case .timeout(let what): return String(localized: "Timeout waiting for \(what)")
        case .unexpectedResponse(let what): return String(localized: "Unexpected response: \(what)")
        case .resultCode(let code, let context):
            return String(localized: "\(context): \(FossilResultCode.describe(code))")
        case .crcMismatch(let what): return String(localized: "CRC mismatch during \(what)")
        case .authenticationFailed(let why): return String(localized: "Authentication failed: \(why)")
        case .missingAuthKey: return String(localized: "No authentication key configured")
        case .notAuthenticated: return String(localized: "Not authenticated with the watch yet")
        case .sessionNotHeld(let name):
            return String(localized: "Internal error: \(name) issued without the watch session")
        case .staleConnection:
            return String(localized: "The active watch connection changed before the operation completed")
        case .cancelled:
            return String(localized: "Operation cancelled")
        }
    }
}
