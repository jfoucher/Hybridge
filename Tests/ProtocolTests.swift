import XCTest
import UIKit
import WeatherKit
@testable import Hybridge

final class ChecksumTests: XCTestCase {
    // Standard test vector: CRC32("123456789") = 0xCBF43926,
    // CRC32C("123456789") = 0xE3069283.
    func testCRC32KnownVector() {
        let data = "123456789".data(using: .ascii)!
        XCTAssertEqual(Checksums.crc32(data), 0xCBF4_3926)
    }

    func testCRC32CKnownVector() {
        let data = "123456789".data(using: .ascii)!
        XCTAssertEqual(Checksums.crc32c(data), 0xE306_9283)
    }
}

final class AESCipherTests: XCTestCase {
    // NIST AES-128 ECB vector works through CBC with zero IV for one block:
    // CBC(zero IV) first block == ECB.
    func testAESCBCZeroIVMatchesNISTVector() throws {
        let key = Data(hexString: "2b7e151628aed2a6abf7158809cf4f3c")!
        let plain = Data(hexString: "6bc1bee22e409f96e93d7e117393172a")!
        let expected = Data(hexString: "3ad77bb40d7a3660a89ecaf32466ef97")!
        let encrypted = try AESCipher.cbcEncrypt(key: key, data: plain)
        XCTAssertEqual(encrypted, expected)
        let decrypted = try AESCipher.cbcDecrypt(key: key, data: encrypted)
        XCTAssertEqual(decrypted, plain)
    }

    // NIST SP 800-38A F.5.1 CTR-AES128.Encrypt, first block.
    func testAESCTRMatchesNISTVector() throws {
        let key = Data(hexString: "2b7e151628aed2a6abf7158809cf4f3c")!
        let iv = Data(hexString: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")!
        let plain = Data(hexString: "6bc1bee22e409f96e93d7e117393172a")!
        let expected = Data(hexString: "874d6191b620e3261bef6864990db6ce")!
        XCTAssertEqual(try AESCipher.ctr(key: key, iv: iv, data: plain), expected)
    }

    func testFileTransferIVConstruction() {
        let phone = Data(hexString: "a1a2a3a4a5a6a7a8")!
        let watch = Data(hexString: "b1b2b3b4b5b6b7b8")!
        let iv = AESCipher.fileTransferIV(phoneRandom: phone, watchRandom: watch)
        // iv[2..7] = phone[0..5], then iv[7]++ (a6 -> a7); iv[9..15] = watch[0..6]
        XCTAssertEqual(iv.hexString, "0000a1a2a3a4a5a700b1b2b3b4b5b6b7")
        XCTAssertEqual(iv.count, 16)
    }
}

final class PayloadTests: XCTestCase {
    func testAlarmTimeCoreRepeating() {
        // Repeating 07:30 on all days: first = 0x80|0x7F = 0xFF,
        // minute 30 | 0x80 = 0x9E, hour 7.
        let alarm = WatchAlarm(hour: 7, minute: 30, daysMask: 0x7F, repeats: true, label: "x")
        XCTAssertEqual(alarm.timeCore, Data([0xFF, 0x9E, 0x07]))
    }

    func testAlarmTimeCoreOneShot() {
        let alarm = WatchAlarm(hour: 22, minute: 5, daysMask: 0, repeats: false, label: "x")
        XCTAssertEqual(alarm.timeCore, Data([0xFF, 0x05, 0x16]))
    }

    func testAlarmTLVFile() {
        let alarm = WatchAlarm(hour: 8, minute: 0, daysMask: 0b0000_0010, repeats: true, label: "Wake")
        let file = WatchAlarm.encodeFile([alarm])
        // alarmSize = 17 + 4 ("Wake") + 3 ("---") = 24; entry = 24 bytes total.
        XCTAssertEqual(file.count, 24)
        XCTAssertEqual(file.u8(at: 0), 0x00)
        XCTAssertEqual(file.u16LE(at: 1), 21)          // alarmSize - 3
        XCTAssertEqual(file.u8(at: 3), 0x00)           // time sub-entry
        XCTAssertEqual(file.u16LE(at: 4), 3)
        XCTAssertEqual(file.slice(6, 3), Data([0x82, 0x80, 0x08]))
        XCTAssertEqual(file.u8(at: 9), 0x01)           // label sub-entry
        XCTAssertEqual(file.u16LE(at: 10), 5)          // "Wake" + null
    }

    func testConfigTimeItemLayout() {
        let item = ConfigItem.time(epochSeconds: 0x1234_5678, millis: 0x0102, offsetMinutes: 120)
        let file = ConfigItem.encodeFile([item])
        XCTAssertEqual(file.hexString, "0c00087856341202017800")
    }

    // GB: HeartRateMeasurementModeItem — config id 0x0E, single signed byte.
    func testConfigHeartRateModeItem() {
        XCTAssertEqual(ConfigItem.encodeFile([.heartRateMode(-1)]).hexString, "0e0001ff")
        XCTAssertEqual(ConfigItem.encodeFile([.heartRateMode(0)]).hexString, "0e000100")
    }

    // GB: TimezoneOffsetConfigItem — config id 0x11 (17), i16 LE minutes.
    func testConfigTimezoneOffsetItem() {
        XCTAssertEqual(ConfigItem.encodeFile([.timezoneOffset(120)]).hexString, "1100027800")
        XCTAssertEqual(ConfigItem.encodeFile([.timezoneOffset(-300)]).hexString, "110002d4fe")
    }

    func testConfigParsesHeartRateModeAndTimezone() {
        var file = Data()
        file.append(ConfigItem.encodeFile([.heartRateMode(-1), .timezoneOffset(-300)]))
        let config = WatchConfiguration.parse(file)
        XCTAssertEqual(config.heartRateMode, -1)
        XCTAssertEqual(config.timezoneOffsetMinutes, -300)
    }

    // Body profile (config 0x0001), all verified by A→B→A capture against the
    // official iOS app: [age u8][gender u8][height cm u16 LE][weight kg u16 LE]
    // [0x00]. Gender: nb=0, male=1, female=2.
    func testBodyProfilePatchPreservesUnknownByte() {
        // Real value read from the watch: age 56, male, height 180, weight 75.
        let base = Data([0x38, 0x01, 0xb4, 0x00, 0x4b, 0x00, 0x00])
        let item = ConfigItem.bodyProfile(base: base, ageYears: 48, gender: .female,
                                          heightCm: 200, weightKg: 70)
        // id 0x0001, len 7, value 30 02 | c8 00 | 46 00 | 00 (byte 6 preserved).
        XCTAssertEqual(ConfigItem.encodeFile([item]).hexString, "0100073002c800460000")
    }

    func testBodyProfileDefaultsToZeroTemplateWhenAbsent() {
        let item = ConfigItem.bodyProfile(base: nil, ageYears: 30, gender: .nonBinary,
                                          heightCm: 175, weightKg: 68)
        XCTAssertEqual(ConfigItem.encodeFile([item]).hexString, "0100071e00af00440000")
    }

    func testConfigParsesBodyProfile() {
        let file = ConfigItem.encodeFile([.bodyProfile(Data([0x30, 0x02, 0xc8, 0x00, 0x46, 0x00, 0x00]))])
        let config = WatchConfiguration.parse(file)
        XCTAssertEqual(config.ageYears, 48)
        XCTAssertEqual(config.gender, ConfigItem.Gender.female.rawValue)
        XCTAssertEqual(config.heightCm, 200)
        XCTAssertEqual(config.weightKg, 70)
        XCTAssertEqual(config.bodyProfileRaw?.hexString, "3002c800460000")
    }

    func testAlarmFileV3RoundTrip() {
        let alarms = [
            WatchAlarm(hour: 7, minute: 30, daysMask: 0b0100_0010, repeats: true, label: "Work"),
            WatchAlarm(hour: 22, minute: 5, daysMask: 0, repeats: false, label: ""),
        ]
        let parsed = WatchAlarm.parseFile(WatchAlarm.encodeFile(alarms), version: 0x03)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].hour, 7)
        XCTAssertEqual(parsed[0].minute, 30)
        XCTAssertEqual(parsed[0].daysMask, 0b0100_0010)
        XCTAssertTrue(parsed[0].repeats)
        XCTAssertEqual(parsed[0].label, "Work")
        XCTAssertEqual(parsed[1].hour, 22)
        XCTAssertEqual(parsed[1].minute, 5)
        XCTAssertFalse(parsed[1].repeats)
        XCTAssertEqual(parsed[1].label, "")   // "---" placeholder maps back to empty
    }

    func testAlarmLegacyFileParse() {
        // Repeating 07:30 all days + one-shot 22:05 (GB: Alarm.fromBytes).
        let parsed = WatchAlarm.parseFile(Data([0xFF, 0x9E, 0x07, 0xFF, 0x05, 0x16]), version: 0x02)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertTrue(parsed[0].repeats)
        XCTAssertEqual(parsed[0].daysMask, 0x7F)
        XCTAssertEqual(parsed[0].minute, 30)
        XCTAssertFalse(parsed[1].repeats)
        XCTAssertEqual(parsed[1].hour, 22)
    }

    // Byte-exact against GB's ConfirmOnDeviceRequest / FactoryResetRequest.
    func testFindWatchAndFactoryResetStartBytes() throws {
        XCTAssertEqual(try ConfirmOnDeviceRequest().startData().hexString, "02063075000000")
        XCTAssertEqual(try FactoryResetRequest().startData().hexString, "02f123ffffffffff")
    }

    func testAppVersionComparison() {
        XCTAssertTrue(InstalledApp.compare("3.8", isOlderThan: "3.9"))
        XCTAssertFalse(InstalledApp.compare("3.13", isOlderThan: "3.9"))
        XCTAssertFalse(InstalledApp.compare("3.9", isOlderThan: "3.9"))
        let stale = InstalledApp(name: "stopwatchApp", version: "3.7", handle: 1)
        XCTAssertEqual(stale.isOutdated, true)
        let unknown = InstalledApp(name: "someRandomApp", version: "1.0", handle: 2)
        XCTAssertNil(unknown.isOutdated)
        let face = InstalledApp(name: "MyFace", version: "1.14", handle: 3)
        XCTAssertEqual(face.isOutdated, false)
    }

    func testStartAppPayload() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JsonPayloads.startApp("stopwatchApp")) as? [String: Any])
        let push = json["push"] as? [String: Any]
        let set = push?["set"] as? [String: Any]
        XCTAssertEqual(set?["customWatchFace._.config.start_app"] as? String, "stopwatchApp")
        XCTAssertNotNil(set?["customWatchFace._.config.start_app_seq"] as? Int)
    }

    // MARK: Notification filter / icons (GB: NotificationFilterPutHRRequest,
    // NotificationImagePutRequest)

    func testNotificationFilterGenericEntry() {
        // "generic" + "general_white.bin" (17 chars): len = 17+18 = 35.
        // CRC32("generic") = 0x964FA1D3 (independent zlib reference), LE.
        let file = NotificationFilterFile.encode([.generic()])
        var expected = "2300"                       // u16 LE 35
        expected += "0404" + "d3a14f96"             // PACKAGE_NAME_CRC
        expected += "800100"                        // GROUP_ID 0
        expected += "c101ff"                        // PRIORITY 0xFF
        expected += "8215ff00" + "12"               // ICON, len 17+4, FF 00, 17+1
        expected += Data("general_white.bin".utf8).hexString + "00"
        XCTAssertEqual(file.hexString, expected)
    }

    func testNotificationFilterCallEntry() {
        // Fixed magic CRC 80 00 59 B7 and the GB-verbatim multi-icon block;
        // len = 19 + 18 + 44 = 81.
        let file = NotificationFilterFile.encode([.call])
        let incoming = Data("icIncomingCall.icon".utf8).hexString
        let missed = Data("icMissedCall.icon".utf8).hexString
        var expected = "5100"
        expected += "0404" + "800059b7"
        expected += "800100"
        expected += "c101ff"
        expected += "82170200"
        expected += "14" + incoming + "00"
        expected += "4000" + "12" + missed + "00"
        expected += "bd00" + "14" + incoming + "00"
        XCTAssertEqual(file.hexString, expected)
    }

    func testNotificationFilterBundleIdCrc() {
        // CRC32("com.apple.MobileSMS") = 0x3F20D0D9 → LE d9d0203f.
        let filter = AppNotificationFilter(packageName: "com.apple.MobileSMS",
                                           iconName: "MobileSMS.icon")
        XCTAssertEqual(filter.packageCrc.hexString, "d9d0203f")
    }

    func testNotificationFilterCatchAllEntry() {
        // Official-app catch-all (byte-verified from a 0x0C00 watch dump):
        // NO CRC TLV, group 7, priority 0xFF, trailing C4=1, no vibration.
        // body = group(3) + icon(2+21=23) + prio(3) + c4(3) = 32.
        let file = NotificationFilterFile.encode([.catchAll()])
        var expected = "2000"
        expected += "800107"
        expected += "8215ff00" + "12" + Data("general_white.bin".utf8).hexString + "00"
        expected += "c101ff"
        expected += "c40101"
        XCTAssertEqual(file.hexString, expected)
    }

    func testNotificationFilterAppEntry() {
        // WhatsApp entry mirrors the official dump: the firmware's ANCS key
        // is CRC32(bundle id + NUL) LE = 19 38 e0 da (dump-verified), group
        // 2, icon before priority 0, vibration 0, C4=1. body = crc(6) +
        // group(3) + icon(2+17=19) + prio(3) + vibe(3) + c4(3) = 37.
        let filter = AppNotificationFilter.app(bundleId: "net.whatsapp.WhatsApp",
                                               iconName: "WhatsApp.icon")
        let file = NotificationFilterFile.encode([filter])
        var expected = "2500"
        expected += "0404" + "1938e0da"
        expected += "800102"
        expected += "8211ff00" + "0e" + Data("WhatsApp.icon".utf8).hexString + "00"
        expected += "c10100"
        expected += "c30100"
        expected += "c40101"
        XCTAssertEqual(file.hexString, expected)
    }

    func testNotificationFilterAncsCrc() {
        // Dump-verified values: the NUL terminator is part of the hash.
        XCTAssertEqual(AppNotificationFilter.ancsCrc("com.shazam.Shazam").hexString, "104ff157")
        XCTAssertEqual(AppNotificationFilter.ancsCrc("com.hammerandchisel.discord").hexString,
                       "a7ce527b")
        XCTAssertEqual(AppNotificationFilter.ancsCrc("org.whispersystems.signal").hexString,
                       "e694f1af")
    }

    func testNotificationFilterBlockedEntry() {
        // Byte-identical to the official dump's blocked Discord entry:
        // 0404 crc 800107 8204ff000100 c10100 c30100 c40100 (len 24).
        let file = NotificationFilterFile.encode([.blocked(bundleId: "com.hammerandchisel.discord")])
        XCTAssertEqual(file.hexString,
                       "18000404a7ce527b8001078204ff000100c10100c30100c40100")
    }

    func testNotificationIconBlockFraming() {
        // size = nameLen(6) + 3 + rle(4) + 2 = 15.
        let icon = WatchNotificationIcon(name: "a.icon", width: 24, height: 24,
                                         rleData: Data([0x10, 0x0C, 0x08, 0x03]))
        let block = icon.block
        XCTAssertEqual(block.u16LE(at: 0), 15)
        XCTAssertEqual(block.count, 17)
        XCTAssertEqual(block.slice(2, 6), Data("a.icon".utf8))
        XCTAssertEqual(block.u8(at: 8), 0x00)       // name terminator
        XCTAssertEqual(block.u8(at: 9), 24)         // width
        XCTAssertEqual(block.u8(at: 10), 24)        // height
        XCTAssertEqual(block.slice(15, 2), Data([0xFF, 0xFF]))
    }

    func testNotificationPlayFileLayout() {
        // GB: PlayNotificationRequest.createFile with type NOTIFICATION (3),
        // flags 0x02. Strings are NUL-terminated; lengths are byte counts.
        let file = NotificationPlayFile.encode(kind: .notification, flags: 0x02,
                                               packageCrc: 0x1122_3344,
                                               title: "T", sender: "Se", message: "Msg",
                                               messageId: 7)
        XCTAssertEqual(Int(file.u16LE(at: 0)), file.count)   // total incl. prefix
        XCTAssertEqual(file.u8(at: 2), 10)                   // length-buffer length
        XCTAssertEqual(file.u8(at: 3), 3)                    // type
        XCTAssertEqual(file.u8(at: 4), 2)                    // flags
        XCTAssertEqual(file.u8(at: 7), 2)                    // title len ("T\0")
        XCTAssertEqual(file.u8(at: 8), 3)                    // sender len
        XCTAssertEqual(file.u8(at: 9), 4)                    // message len
        XCTAssertEqual(file.u32LE(at: 10), 7)                // message id
        XCTAssertEqual(file.u32LE(at: 14), 0x1122_3344)      // package crc
        XCTAssertEqual(file.slice(18, 2), Data("T\0".utf8))
        XCTAssertEqual(file.slice(20, 3), Data("Se\0".utf8))
        XCTAssertEqual(file.slice(23, 4), Data("Msg\0".utf8))
    }

    // Byte-exact against GB's misfit hand-control requests (HR variant:
    // 1-degree moves are not rounded up).
    func testHandControlPayloads() throws {
        XCTAssertEqual(try RequestHandsControlRequest().payload().hexString, "021501010000")
        XCTAssertEqual(try ReleaseHandsControlRequest().payload().hexString, "0215020000")
        XCTAssertEqual(try SaveCalibrationRequest().payload().hexString, "02f20e")
    }

    func testMoveHandsRelative() throws {
        // hour +100 (clockwise), minute -10 (counter-clockwise), speed 1.
        let move = MoveHandsRequest(relative: true, hour: 100, minute: -10)
        XCTAssertEqual(try move.payload().hexString,
                       "0215030102" + "0164000101" + "020a000201")
    }

    func testMoveHandsAbsoluteToZero() throws {
        // Absolute moves use direction 3 (shortest path).
        let move = MoveHandsRequest(relative: false, hour: 0, minute: 0)
        XCTAssertEqual(try move.payload().hexString,
                       "0215030202" + "0100000301" + "0200000301")
    }

    // Calibration start on a Q zeroes the sub-eye too (hand id 3) —
    // GB QHYBRID_COMMAND_CONTROL sets all three hands.
    func testMoveHandsAbsoluteWithSubEye() throws {
        let move = MoveHandsRequest(relative: false, hour: 0, minute: 0, sub: 0)
        XCTAssertEqual(try move.payload().hexString,
                       "0215030203" + "0100000301" + "0200000301" + "0300000301")
    }

    func testMoveHandsRelativeSubEye() throws {
        let move = MoveHandsRequest(relative: true, sub: -10)
        XCTAssertEqual(try move.payload().hexString, "0215030101" + "030a000201")
    }

    func testMoveHandsSingleHand() throws {
        let move = MoveHandsRequest(relative: true, minute: 1)
        XCTAssertEqual(try move.payload().hexString, "0215030101" + "0201000101")
    }

    // GB's !isHybridHR quirk: |1°| becomes 2°, direction preserved; other
    // magnitudes untouched.
    func testMoveHandsBumpSingleDegreeForQ() throws {
        let plusOne = MoveHandsRequest(relative: true, minute: 1, bumpSingleDegree: true)
        XCTAssertEqual(try plusOne.payload().hexString, "0215030101" + "0202000101")
        let minusOne = MoveHandsRequest(relative: true, hour: -1, bumpSingleDegree: true)
        XCTAssertEqual(try minusOne.payload().hexString, "0215030101" + "0102000201")
        let two = MoveHandsRequest(relative: true, minute: 2, bumpSingleDegree: true)
        XCTAssertEqual(try two.payload().hexString, "0215030101" + "0202000101")
    }

    // Byte-exact against GB FossilWatchAdapter.vibrateStartCall/vibrateEndCall
    // and the misfit AnimationRequest.
    func testQVibrateAndAnimationStartBytes() throws {
        XCTAssertEqual(try QVibrateRequest(start: true).startData().hexString, "010430750000")
        XCTAssertEqual(try QVibrateRequest(start: false).startData().hexString, "020504")
        XCTAssertEqual(try PairingAnimationRequest().startData().hexString, "02f105")
    }

    // The GB init triple (FossilWatchAdapter.syncConfiguration): step goal +
    // vibration strength + timezone offset as one TLV file.
    func testQInitTripleConfigFile() {
        let file = ConfigItem.encodeFile([
            .dailyStepGoal(10000),
            .vibrationStrength(50),
            .timezoneOffset(120),
        ])
        XCTAssertEqual(file.hexString, "030004102700000a0001321100027800")
    }

    // Legacy alarm file (file version != 3) is just the 3-byte cores
    // back to back — GB AlarmsSetRequest's old format.
    func testAlarmLegacyFileEncode() {
        let alarms = [
            WatchAlarm(hour: 7, minute: 30, daysMask: 0x7F, repeats: true, label: "ignored"),
            WatchAlarm(hour: 22, minute: 5, daysMask: 0, repeats: false, label: ""),
        ]
        XCTAssertEqual(WatchAlarm.encodeLegacyFile(alarms).hexString, "ff9e07" + "ff0516")
    }

    // Byte-oracle from a real Q Grant configured by the official iOS app
    // (notificationFilter_0C003.bin dump, 2026-07-13): WhatsApp at 300°
    // vibe 4, and the contact "Florent" at 30° as a paired call+SMS entry.
    func testQNotificationFilterMatchesGrantDump() {
        let alerts = [
            QNotificationAlert(kind: .app, identifier: "net.whatsapp.WhatsApp",
                               displayName: "WhatsApp", degrees: 300, vibration: .standard),
            QNotificationAlert(kind: .contact, identifier: "Florent",
                               displayName: "Florent", degrees: 30),
        ]
        let whatsapp = "1e00" + "0404" + "1938e0da" + "800102" + "c10100"
            + "c20a" + "2c012c01ffff1027feff" + "c30104" + "c40100"
        let florent = "0208" + "466c6f72656e7400"
        let florentCall = "2800" + florent + "0404" + "800059b7" + "800101" + "c10100"
            + "c20a" + "1e001e00ffff1027feff" + "c30101" + "c40100"
        let florentSms = "2800" + florent + "0404" + "2da5322d" + "800102" + "c10100"
            + "c20a" + "1e001e00ffff1027feff" + "c30102" + "c40100"
        XCTAssertEqual(QNotificationFilterFile.encode(alerts).hexString,
                       whatsapp + florentCall + florentSms)
    }

    // GB's syncNotificationSettings duplicates a single-entry file.
    func testQNotificationFilterDuplicatesSingleEntry() {
        let alert = QNotificationAlert(kind: .app, identifier: "net.whatsapp.WhatsApp",
                                       displayName: "WhatsApp", degrees: 300, vibration: .standard)
        let file = QNotificationFilterFile.encode([alert])
        XCTAssertEqual(file.count, 64)   // 32-byte entry, twice
        XCTAssertEqual(file.prefix(32), file.suffix(32))
        // A contact alert already yields two entries — no duplication.
        // Body: name TLV 4 ("A\0") + crc 6 + group 3 + prio 3 + movement 12
        // + vibe 3 + c4 3 = 34, plus the u16 length prefix.
        let contact = QNotificationAlert(kind: .contact, identifier: "A",
                                         displayName: "A", degrees: 30)
        XCTAssertEqual(QNotificationFilterFile.encode([contact]).count, 2 * 36)
    }

    // MARK: Quiet-hours night filters

    func testHRNightFilterIsGenericEntryOnly() {
        // The block-everything file is exactly the generic entry: non-empty,
        // matches no real ANCS bundle-id CRC, but keeps the app's own
        // test-notification path (which targets "generic") working.
        let night = NotificationFilterFile.nightFilter()
        XCTAssertFalse(night.isEmpty)
        XCTAssertEqual(night, NotificationFilterFile.encode([.generic()]))
    }

    func testQNightFilterIsNonEmptyDuplicatedStub() {
        let night = QNotificationFilterFile.nightFilter()
        XCTAssertFalse(night.isEmpty)
        // A single-entry file is duplicated by the GB firmware-quirk
        // workaround — same as any other lone entry.
        XCTAssertEqual(night.count % 2, 0)
        XCTAssertEqual(night.prefix(night.count / 2), night.suffix(night.count / 2))
        // The stub bundle id's CRC must not collide with a real app's (using
        // WhatsApp's dump-verified CRC as a stand-in for "any curated app").
        let whatsappCrc = AppNotificationFilter.ancsCrc("net.whatsapp.WhatsApp")
        let stubCrc = AppNotificationFilter.ancsCrc("eu.sixpixels.hybridge.quiet")
        XCTAssertNotEqual(stubCrc, whatsappCrc)
    }

    // Same function on all three buttons stores a single deduplicated
    // payload (and its single customization record).
    func testQButtonConfigFileDeduplicated() {
        let file = QButtonConfigFile.build([.date, .date, .date])
        let dateHeader = "01011400"
        let expectedPrefix = "010000" + "03"
            + "1001" + dateHeader + "00"
            + "2001" + dateHeader + "00"
            + "3001" + dateHeader + "00"
            + "01"
        XCTAssertTrue(file.hexString.hasPrefix(expectedPrefix))
        // prefix + one 45-byte blob + cust count + one 10-byte record + CRC32
        XCTAssertEqual(file.count, 4 + 3 * 7 + 1 + 45 + 1 + 10 + 4)
        let body = file.prefix(file.count - 4)
        XCTAssertEqual(file.u32LE(at: file.count - 4), Checksums.crc32(body))
    }

    func testQButtonConfigFileDistinctPayloads() {
        let file = QButtonConfigFile.build([.forwardToPhone, .musicControl, .date])
        // Payload count byte sits right after the 3 button-table entries.
        XCTAssertEqual(file.u8(at: 4 + 3 * 7), 3)
        // Payloads are keyed by their embedded id: musicControl and
        // forwardToPhoneMulti share one, so the identical blob is stored once.
        let twins = QButtonConfigFile.build([.musicControl, .forwardToPhoneMulti, .date])
        XCTAssertEqual(twins.u8(at: 4 + 3 * 7), 2)
        XCTAssertEqual(QButtonFunction.musicControl.entries,
                       QButtonFunction.forwardToPhoneMulti.entries)
    }

    // Each payload blob carries its own trailing CRC32 over the blob body.
    func testQButtonBlobsSelfConsistent() {
        for function in QButtonFunction.allCases {
            for entry in function.entries {
                XCTAssertGreaterThan(entry.blob.count, 8, function.rawValue)
                XCTAssertEqual(entry.blob.u32LE(at: entry.blob.count - 4),
                               Checksums.crc32(entry.blob.prefix(entry.blob.count - 4)),
                               "\(function.rawValue) blob CRC")
            }
        }
    }

    // Real-watch verified (Q Grant, physical press): GB's labels for these
    // two are correct — 01051200 lowers volume, 01021c00 shows step goal.
    // (An earlier stale-config test led us to swap them; don't repeat that.)
    func testQButtonVolumeDownStepGoalMatchGB() {
        XCTAssertEqual(QButtonFunction.volumeDown.entries[0].header.hexString, "01051200")
        XCTAssertEqual(QButtonFunction.stepGoalCompletion.entries[0].header.hexString, "01021c00")
    }

    // Byte-oracle from the official iOS app's file (settingsButtons_0600.bin,
    // real Q Grant): the "alternate" function registers the four sub-eye
    // payloads (alert, time 2, alarm, date) the button cycles through.
    func testQButtonAlternateMatchesGrantDump() {
        let entries = QButtonFunction.alternate.entries
        XCTAssertEqual(entries.map { $0.header.hexString },
                       ["01021800", "01021600", "01021a00", "01021400"])
        XCTAssertEqual(entries[0].blob.hexString,
            "010001021836000000010008000400000702010001011d0089020104b0020089050107b00200b00200b002000801500001009cf6efcd")
        XCTAssertEqual(entries[1].blob.hexString,
            "010001021636000000010008000400000702020001011d0089020104b0010089050107b00100b00100b00100080150000100c8b78887")
        XCTAssertEqual(entries[2].blob.hexString,
            "010001021a36000000010008000400000702000001011d0089020104b0030089050107b00300b00300b00300080150000100a67957cc")
        XCTAssertEqual(entries[3].blob.hexString,
            "01000102143400000001000600020000070001011d0089020104b0000089050107b00000b00000b00000080150000100779c0c19")
    }

    // Full-file structure with alternate on the middle button, mirroring the
    // official dump's shape (button table, payload set, customization
    // records — one per payload, [header][0A 00][01 02 01 00]).
    func testQButtonConfigFileWithAlternate() {
        let file = QButtonConfigFile.build([.musicControl, .alternate, .date])
        let expectedTable = "010000" + "03"
            + "1001" + "01061200" + "00"
            + "2004" + "0102180000" + "0102160000" + "01021a0000" + "0102140000"
            + "3001" + "01011400" + "00"
            + "06"   // musicControl + 4 alternate + date payloads
        XCTAssertTrue(file.hexString.hasPrefix(expectedTable))
        let payloadBytes = 99 + 54 + 54 + 54 + 52 + 45
        let customization = "06"
            + "010612000a0001020100"
            + "010218000a0001020100"
            + "010216000a0001020100"
            + "01021a000a0001020100"
            + "010214000a0001020100"
            + "010114000a0001020100"
        let customizationOffset = expectedTable.count / 2 + payloadBytes
        XCTAssertEqual(file.slice(customizationOffset, customization.count / 2).hexString,
                       customization)
        XCTAssertEqual(file.count, customizationOffset + customization.count / 2 + 4)
        XCTAssertEqual(file.u32LE(at: file.count - 4),
                       Checksums.crc32(file.prefix(file.count - 4)))
    }

    func testQClockPositionDegrees() {
        XCTAssertEqual(QNotificationAlert.degrees(forClockPosition: 1), 30)
        XCTAssertEqual(QNotificationAlert.degrees(forClockPosition: 6), 180)
        XCTAssertEqual(QNotificationAlert.degrees(forClockPosition: 12), 359)
    }

    // Byte-oracle from a real Q Grant configured by the official iOS app
    // (alarms_0A00.bin dump, 2026-07-13): repeating 08:30, days 0b0110110.
    func testAlarmLegacyMatchesGrantDump() {
        let alarm = WatchAlarm(hour: 8, minute: 30, daysMask: 0b0110110, repeats: true, label: "")
        XCTAssertEqual(WatchAlarm.encodeLegacyFile([alarm]).hexString, "b69e08")
        let parsed = WatchAlarm.parseFile(Data([0xB6, 0x9E, 0x08]), version: 0x02)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].hour, 8)
        XCTAssertEqual(parsed[0].minute, 30)
        XCTAssertEqual(parsed[0].daysMask, 0b0110110)
        XCTAssertTrue(parsed[0].repeats)
    }

    func testDeviceFileVersionsParsing() {
        // TLV record 0x0A: [0a 00][06][01 aa 00 0a bb 00]
        var file = Data()
        file.appendUInt16LE(0x0A)
        file.append(6)
        file.append(contentsOf: [0x01, 0xAA, 0x00, 0x0A, 0xBB, 0x00])
        let versions = DeviceFileVersions(deviceInfoFile: file)
        XCTAssertEqual(versions.version(for: .activity), 0x00AA)
        XCTAssertEqual(versions.version(for: .alarms), 0x00BB)
        XCTAssertEqual(versions.version(for: .appCode), 0x0003) // fixed addition
    }
}

final class WappBuilderTests: XCTestCase {
    func testContainerLayoutMatchesFossilFormat() {
        // Build a tiny container and validate the header/section framing that
        // FossilFileReader/the watch expect.
        let code: [(String, Data)] = [("Face", Data([0x01, 0x02, 0x03]))]
        let icons: [(String, Data)] = [("background.raw", Data(repeating: 0xAB, count: 8))]
        let layout: [(String, Data)] = [("image_layout", Data("[]".utf8))]
        let displayName: [(String, String)] = [("display_name", "Face")]
        let config: [(String, String)] = [("customWatchFace", "{}")]

        let wapp = WappBuilder.assembleWapp(version: (1, 13),
                                            code: code, icons: icons, layout: layout,
                                            displayName: displayName, config: config)

        // Outer header
        XCTAssertEqual(wapp.slice(0, 2), Data([0xFE, 0x15]))
        XCTAssertEqual(wapp.slice(2, 2), Data([0x03, 0x00]))
        XCTAssertEqual(wapp.u32LE(at: 4), 0)
        let filePartLength = Int(wapp.u32LE(at: 8))
        XCTAssertEqual(wapp.count, 12 + filePartLength + 4)

        // Inner header
        XCTAssertEqual(wapp.u8(at: 12), 0x01)           // watchface type
        XCTAssertEqual(wapp.u8(at: 13), 1)              // version major
        XCTAssertEqual(wapp.u8(at: 14), 13)             // version minor
        XCTAssertEqual(wapp.u32LE(at: 12 + 12), 88)     // offsetCode

        // code section entry framing at absolute offset 88
        let nameLength = Int(wapp.u8(at: 88))
        XCTAssertEqual(nameLength, "Face".count + 1)
        XCTAssertEqual(String(data: wapp.slice(89, 4), encoding: .utf8), "Face")
        XCTAssertEqual(wapp.u8(at: 93), 0)
        XCTAssertEqual(wapp.u16LE(at: 94), 3)           // content length

        // CRC32C over the file part
        let filePart = wapp.slice(12, filePartLength)
        XCTAssertEqual(wapp.u32LE(at: 12 + filePartLength), Checksums.crc32c(filePart))

        // Section offsets chain up to file end
        let offsetIcons = Int(wapp.u32LE(at: 12 + 16))
        let offsetLayout = Int(wapp.u32LE(at: 12 + 20))
        let offsetDisplayName = Int(wapp.u32LE(at: 12 + 24))
        let offsetConfig = Int(wapp.u32LE(at: 12 + 32))
        let offsetFileEnd = Int(wapp.u32LE(at: 12 + 36))
        XCTAssertEqual(offsetFileEnd, 12 + filePartLength)
        XCTAssertLessThan(offsetIcons, offsetLayout)
        XCTAssertLessThan(offsetLayout, offsetDisplayName)
        XCTAssertLessThan(offsetDisplayName, offsetConfig)

        // layout section content is null-terminated with +1 length
        let layoutNameLength = Int(wapp.u8(at: offsetLayout))
        let layoutContentLength = Int(wapp.u16LE(at: offsetLayout + 1 + layoutNameLength))
        XCTAssertEqual(layoutContentLength, "[]".count + 1)
    }

    func testWappBackgroundRoundTrip() {
        // 240×240 2bpp: all pixels value 3 (white), except the very first
        // pixel (0,0) = 0. Stored reversed, so (0,0) lives in the low bits
        // of the last byte.
        var raw = Data(repeating: 0xFF, count: 240 * 240 / 4)
        raw[raw.count - 1] = 0xFC

        let wapp = WappBuilder.assembleWapp(version: (1, 13),
                                            code: [("Face", Data([0x01]))],
                                            icons: [("!preview.rle", Data([0, 0])),
                                                    ("background.raw", raw)],
                                            layout: [("image_layout", Data("[]".utf8))],
                                            displayName: [("display_name", "Face")],
                                            config: [("customWatchFace", "{}")])

        let image = WappReader.backgroundImage(fromWapp: wapp)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.cgImage?.width, 240)
        XCTAssertEqual(image?.cgImage?.height, 240)

        // Check the two known pixels via the raw grayscale bitmap.
        if let cgImage = image?.cgImage, let pixelData = cgImage.dataProvider?.data as Data? {
            let bytesPerRow = cgImage.bytesPerRow
            XCTAssertEqual(pixelData[0], 0)                       // (0,0) black
            XCTAssertEqual(pixelData[bytesPerRow * 120 + 120], 255)  // center white
        } else {
            XCTFail("no bitmap data")
        }
    }

    func testWappReaderRejectsGarbage() {
        XCTAssertNil(WappReader.backgroundImage(fromWapp: Data(repeating: 0x42, count: 400)))
        XCTAssertNil(WappReader.backgroundImage(fromWapp: Data()))
        XCTAssertEqual(WappReader.widgets(fromWapp: Data(repeating: 0x42, count: 400)).count, 0)
    }

    func testDumpRingFaceConfigJSON() throws {
        // Diagnostic: print the exact customWatchFace JSON a ring face ships.
        var design = WatchfaceDesign(name: "RingTest")
        design.widgets = [
            WatchfaceWidget(type: "widgetSteps", x: 120, y: 58, color: 0,
                            background: "widget_bg_thin_circle", goalRing: true),
        ]
        let wapp = try WappBuilder(design: design).build()
        // config section: [len]["customWatchFace\0"][u16 size][json\0]
        let marker = Data("customWatchFace".utf8)
        guard let range = wapp.range(of: marker) else { return XCTFail("no config entry") }
        let sizeAt = range.upperBound + 1
        let size = Int(wapp.u16LE(at: sizeAt))
        let json = wapp.slice(sizeAt + 2, size - 1)
        print("RING-FACE-CONFIG: \(String(data: json, encoding: .utf8) ?? "?")")
        // Also list the code/icons entries.
        let iconsStart = Int(wapp.u32LE(at: 12 + 16))
        var names: [String] = []
        var offset = 88
        while offset + 4 <= iconsStart {
            let nameLength = Int(wapp.u8(at: offset))
            guard nameLength > 0 else { break }
            names.append(String(data: wapp.slice(offset + 1, nameLength - 1), encoding: .utf8) ?? "?")
            offset += 1 + nameLength
            offset += 2 + Int(wapp.u16LE(at: offset))
        }
        print("RING-FACE-CODE: \(names.joined(separator: ", "))")
    }

    func testWappWidgetsRoundTrip() {
        // customWatchFace JSON in the shape WappBuilder.configurationJSON
        // writes; WappReader.widgets must recover the complications.
        let config = """
        {"layout":[\
        {"type":"image","name":"background.raw","pos":{"x":120,"y":120},"size":{"w":240,"h":240}},\
        {"type":"comp","name":"widgetStepsR","pos":{"x":120,"y":58},"size":{"w":76,"h":76},\
        "color":"white","goal_ring":false,"bg":"wbg_thin_circle_fill0.rle"},\
        {"type":"comp","name":"widgetDate","pos":{"x":58,"y":120},"size":{"w":76,"h":76},\
        "color":"black","goal_ring":false,"bg":"wbg_solid1.rle"}\
        ],"config":{}}
        """
        let wapp = WappBuilder.assembleWapp(version: (1, 13),
                                            code: [("Face", Data([0x01]))],
                                            icons: [("background.raw", Data(repeating: 0xFF, count: 240 * 240 / 4))],
                                            layout: [("image_layout", Data("[]".utf8))],
                                            displayName: [("display_name", "Face")],
                                            config: [("customWatchFace", config)])

        let widgets = WappReader.widgets(fromWapp: wapp)
        XCTAssertEqual(widgets.count, 2)
        XCTAssertEqual(widgets[0].type, "widgetSteps")
        XCTAssertEqual(widgets[0].x, 120)
        XCTAssertEqual(widgets[0].y, 58)
        XCTAssertEqual(widgets[0].color, 0)
        XCTAssertEqual(widgets[0].background, "widget_bg_thin_circle")
        XCTAssertTrue(widgets[0].goalRing)
        XCTAssertTrue(widgets[0].solidFill)
        XCTAssertEqual(widgets[1].type, "widgetDate")
        XCTAssertEqual(widgets[1].color, 1)
        XCTAssertEqual(widgets[1].background, "")
        XCTAssertFalse(widgets[1].goalRing)
        XCTAssertTrue(widgets[1].solidFill)
    }

    func testWidgetBackgroundRLENames() {
        var widget = WatchfaceWidget(type: "widgetSteps", x: 120, y: 58,
                                     color: 0, background: "")
        XCTAssertNil(widget.backgroundRLEName)
        widget.solidFill = true
        XCTAssertEqual(widget.backgroundRLEName, "wbg_solid0.rle")
        widget.background = "widget_bg_thin_circle"
        XCTAssertEqual(widget.backgroundRLEName, "wbg_thin_circle_fill0.rle")
        widget.solidFill = false
        widget.color = 1
        XCTAssertEqual(widget.backgroundRLEName, "widget_bg_thin_circle1.rle")
    }

    func testGoalRingOnlyForSupportedTypes() {
        var widget = WatchfaceWidget(type: "widgetDate", x: 120, y: 58,
                                     color: 0, background: "", goalRing: true)
        XCTAssertFalse(widget.wantsGoalRing)
        XCTAssertEqual(widget.codeName, "widgetDate")
        widget.type = "widgetSteps"
        XCTAssertTrue(widget.wantsGoalRing)
        XCTAssertEqual(widget.codeName, "widgetStepsR")
        widget.goalRing = false
        XCTAssertEqual(widget.codeName, "widgetSteps")
    }

    func testHRWidgetNameNotMistakenForRingVariant() throws {
        // "widgetHR" ends in R; dropping it gives "widgetH", not a ring type.
        var design = WatchfaceDesign(name: "HRFace")
        design.widgets = [WatchfaceWidget(type: "widgetHR", x: 120, y: 58,
                                          color: 0, background: "")]
        let wapp = try WappBuilder(design: design).build()
        let widgets = WappReader.widgets(fromWapp: wapp)
        XCTAssertEqual(widgets.count, 1)
        XCTAssertEqual(widgets[0].type, "widgetHR")
        XCTAssertFalse(widgets[0].goalRing)
    }

    /// customFace architecture: the code section is a SINGLE entry — the
    /// author-original engine blob keyed under the face name — with no
    /// per-widget or widgetText blobs, and the layout section is the single
    /// generated node tree (cf_layout).
    func testCustomFaceSingleCodeEntryAndGeneratedLayout() throws {
        var design = WatchfaceDesign(name: "Mono")
        design.widgets = [
            WatchfaceWidget(type: "widgetSteps", x: 120, y: 58, color: 0, background: "", goalRing: true),
            WatchfaceWidget(type: "widgetHR", x: 120, y: 182, color: 0, background: ""),
        ]
        let wapp = try WappBuilder(design: design).build()

        let offsetIcons = Int(wapp.u32LE(at: 12 + 16))
        let offsetLayout = Int(wapp.u32LE(at: 12 + 20))
        let offsetDisplayName = Int(wapp.u32LE(at: 12 + 24))
        let codeNames = sectionEntryNames(wapp, from: 88, to: offsetIcons)
        let layoutNames = sectionEntryNames(wapp, from: offsetLayout, to: offsetDisplayName)

        XCTAssertEqual(codeNames, ["Mono"], "one engine blob keyed under the face name")
        XCTAssertFalse(codeNames.contains { $0.hasPrefix("widget") }, "no GB per-widget blobs")
        XCTAssertEqual(layoutNames, [CustomFaceLayout.layoutName], "single generated layout")
    }

    /// The field map wires each placeholder to a get_common() source, and the
    /// generated node tree carries the matching #placeholders (value text +
    /// goal-ring arc).
    func testCustomFaceFieldMapAndPlaceholders() throws {
        let result = CustomFaceLayout.generate(for: {
            var d = WatchfaceDesign(name: "Fields")
            d.widgets = [WatchfaceWidget(type: "widgetSteps", x: 120, y: 58,
                                         color: 0, background: "", goalRing: true)]
            return d
        }())
        let text = try XCTUnwrap(result.fields["text"] as? [[String: Any]])
        let rings = try XCTUnwrap(result.fields["rings"] as? [[String: Any]])
        XCTAssertTrue(text.contains { $0["src"] as? String == "steps" && $0["ph"] as? String == "v0" })
        XCTAssertTrue(rings.contains { $0["src"] as? String == "steps" && $0["ph"] as? String == "r0" })

        let texts = result.layout.compactMap { $0["text"] as? String }
        XCTAssertTrue(texts.contains("#v0"))
        let arc = try XCTUnwrap(result.layout.first { ($0["type"] as? String) == "arc" })
        let arcInfo = try XCTUnwrap(arc["arc_info"] as? [String: Any])
        XCTAssertEqual(arcInfo["end_angle"] as? String, "#r0")
    }

    /// Regression: the layout_parser_json image node draws RLE, not the raw
    /// base-layer format. The background must be packed as an RLE named
    /// "background" (starting with the [w][h] = [240,240] header) and the
    /// generated layout's background node must reference it — else nothing
    /// shows on the watch.
    func testBackgroundPackedAsRLEForLayoutImageNode() throws {
        var design = WatchfaceDesign(name: "BG")
        design.widgets = [WatchfaceWidget(type: "widgetDate", x: 120, y: 120, color: 0, background: "")]
        let wapp = try WappBuilder(design: design).build()

        let offsetIcons = Int(wapp.u32LE(at: 12 + 16))
        let offsetLayout = Int(wapp.u32LE(at: 12 + 20))
        let iconNames = sectionEntryNames(wapp, from: offsetIcons, to: offsetLayout)
        XCTAssertTrue(iconNames.contains("background"), "RLE background must be packed for the layout image node")

        let result = CustomFaceLayout.generate(for: design)
        let bg = try XCTUnwrap(result.layout.first { ($0["type"] as? String) == "image" })
        XCTAssertEqual(bg["image_name"] as? String, "background")
    }

    /// The date complication stacks the day number above the weekday, centered
    /// in the circle: two text sources ("date" and "day"), localized day names
    /// shipped, and no icon.
    func testDateComplicationShowsWeekday() throws {
        var design = WatchfaceDesign(name: "D")
        design.widgets = [WatchfaceWidget(type: "widgetDate", x: 120, y: 120, color: 0, background: "")]
        let result = CustomFaceLayout.generate(for: design)
        let text = try XCTUnwrap(result.fields["text"] as? [[String: Any]])
        XCTAssertTrue(text.contains { $0["src"] as? String == "date" })
        XCTAssertTrue(text.contains { $0["src"] as? String == "day" })
        XCTAssertEqual(result.fields["days"] as? [String], WatchfaceValueSource.weekdayNames())
        XCTAssertTrue(result.iconAssets.isEmpty, "date has no icon")

        // The day number sits above the weekday.
        func centerY(forText ph: String) -> Int? {
            guard let textNode = result.layout.first(where: { ($0["text"] as? String) == "#\(ph)" }),
                  let parent = textNode["parent_id"] as? Int,
                  let container = result.layout.first(where: { ($0["id"] as? Int) == parent }),
                  let placement = container["placement"] as? [String: Any],
                  let top = placement["top"] as? Int,
                  let dim = container["dimension"] as? [String: Any],
                  let h = dim["height"] as? Int else { return nil }
            return top + h / 2
        }
        let dateY = try XCTUnwrap(centerY(forText: "v0"))
        let dayY = try XCTUnwrap(centerY(forText: "w0"))
        XCTAssertLessThan(dateY, dayY, "day number must sit above the weekday")
    }

    /// The show-icon toggle drops the icon node + its packed asset; a black
    /// complication packs the black-ink icon variant.
    func testShowIconToggleAndBlackVariant() throws {
        var withIcon = WatchfaceWidget(type: "widgetSteps", x: 120, y: 120, color: 0, background: "")
        withIcon.showIcon = true
        XCTAssertTrue(CustomFaceLayout.generate(for: face(withIcon)).iconAssets.contains("icSteps"))

        var hidden = withIcon
        hidden.showIcon = false
        XCTAssertTrue(CustomFaceLayout.generate(for: face(hidden)).iconAssets.isEmpty)

        var black = withIcon
        black.color = 1
        XCTAssertTrue(CustomFaceLayout.generate(for: face(black)).iconAssets.contains("icStepsB"))
    }

    /// A face that would exceed the firmware's node ceiling fails to build with
    /// a clear error rather than shipping a blank-screen face.
    func testTooManyNodesThrows() {
        var design = WatchfaceDesign(name: "Busy")
        // Six complications, each with a goal ring + background circle + icon +
        // value → well past CustomFaceLayout.maxNodes.
        design.widgets = (0..<6).map { i in
            WatchfaceWidget(type: "widgetSteps", x: 40 + i * 30, y: 120, color: 0,
                            background: "widget_bg_thin_circle", goalRing: true)
        }
        XCTAssertThrowsError(try WappBuilder(design: design).build()) { error in
            guard case WappError.tooManyElements = error else {
                return XCTFail("expected tooManyElements, got \(error)")
            }
        }
    }

    private func face(_ widget: WatchfaceWidget) -> WatchfaceDesign {
        var d = WatchfaceDesign(name: "F")
        d.widgets = [widget]
        return d
    }

    /// Walks a packed section ([len][name\0][u16 size][content...] entries,
    /// same format WappBuilder.packEntries/packStringEntries write) and
    /// returns just the entry names — same pattern testDumpRingFaceConfigJSON
    /// uses inline for the code section, generalized to any section.
    private func sectionEntryNames(_ wapp: Data, from start: Int, to end: Int) -> [String] {
        var names: [String] = []
        var offset = start
        while offset + 4 <= end {
            let nameLength = Int(wapp.u8(at: offset))
            guard nameLength > 0 else { break }
            names.append(String(data: wapp.slice(offset + 1, nameLength - 1), encoding: .utf8) ?? "?")
            offset += 1 + nameLength
            offset += 2 + Int(wapp.u16LE(at: offset))
        }
        return names
    }


    /// A dynamic (valueSource != nil) text layer renders in the user's custom
    /// font: a `glyphs` field entry, one image node per character slot carrying
    /// its #placeholder, baked glyph RLEs to pack, and a `text_layers` preview
    /// record.
    func testDynamicTextLayerBecomesGlyphEntry() throws {
        var design = WatchfaceDesign(name: "Dynamic")
        design.textLayers = [
            WatchfaceTextLayer(text: "unused", x: 120, y: 180, fontSize: 32,
                               valueSource: .steps),
        ]
        let result = CustomFaceLayout.generate(for: design)
        let glyphs = try XCTUnwrap(result.fields["glyphs"] as? [[String: Any]])
        let g0 = try XCTUnwrap(glyphs.first { $0["pre"] as? String == "t0" })
        XCTAssertEqual(g0["src"] as? String, "steps")
        XCTAssertNotNil(g0["cw"] as? [String: Int])
        XCTAssertEqual(g0["fb"] as? String, g0["fb"] as? String) // present
        // One image node per slot, referencing the glyph placeholders.
        let imageNames = result.layout.compactMap { $0["image_name"] as? String }
        XCTAssertTrue(imageNames.contains("#t0g0"))
        // Baked glyph atlas to pack (non-empty RLEs, layer-prefixed names).
        XCTAssertFalse(result.glyphImages.isEmpty)
        XCTAssertTrue(result.glyphImages.contains { $0.name.hasPrefix("t0") })
        XCTAssertTrue(result.glyphImages.allSatisfy { !$0.rle.isEmpty })

        let meta = try XCTUnwrap(result.textLayerMeta.first)
        XCTAssertEqual(meta["src"] as? String, "steps")
        XCTAssertEqual(meta["x"] as? Int, 120)
        XCTAssertEqual(meta["y"] as? Int, 180)

        // Round-trips through the config for a downloaded-face preview.
        let wapp = try WappBuilder(design: design).build()
        let previews = WappReader.textLayers(fromWapp: wapp)
        XCTAssertEqual(previews.count, 1)
        XCTAssertEqual(previews.first?.source, .steps)
    }

    /// A weekday source ships the localized Sunday-first day names once, in the
    /// field map (customFace maps get_common().day through them).
    func testWeekdayLayerShipsLocalizedDayNames() throws {
        var design = WatchfaceDesign(name: "Days")
        design.textLayers = [
            WatchfaceTextLayer(text: "unused", x: 120, y: 60, fontSize: 28,
                               valueSource: .weekday),
        ]
        let result = CustomFaceLayout.generate(for: design)
        let days = try XCTUnwrap(result.fields["days"] as? [String])
        XCTAssertEqual(days, WatchfaceValueSource.weekdayNames())
        let glyphs = try XCTUnwrap(result.fields["glyphs"] as? [[String: Any]])
        XCTAssertTrue(glyphs.contains { $0["src"] as? String == "day" })
    }

    /// Dynamic layers get distinct glyph prefixes/sources — and more than two
    /// are allowed now (the old GB two-widget cap is gone; the node budget is
    /// the only limit).
    func testMultipleDynamicLayersAllowed() throws {
        var design = WatchfaceDesign(name: "Many")
        design.textLayers = [
            WatchfaceTextLayer(text: "", x: 120, y: 60, fontSize: 24, valueSource: .weekday),
            WatchfaceTextLayer(text: "", x: 120, y: 120, fontSize: 24, valueSource: .heartRate),
            WatchfaceTextLayer(text: "", x: 120, y: 180, fontSize: 24, valueSource: .battery),
        ]
        let result = CustomFaceLayout.generate(for: design)
        let glyphs = try XCTUnwrap(result.fields["glyphs"] as? [[String: Any]])
        XCTAssertTrue(glyphs.contains { $0["pre"] as? String == "t0" && $0["src"] as? String == "day" })
        XCTAssertTrue(glyphs.contains { $0["pre"] as? String == "t1" && $0["src"] as? String == "hr" })
        XCTAssertTrue(glyphs.contains { $0["pre"] as? String == "t2" && $0["src"] as? String == "bat" })
        XCTAssertEqual(result.textLayerMeta.count, 3)
        // Three short layers stay under the node budget → builds fine.
        XCTAssertNoThrow(try WappBuilder(design: design).build())
    }

    /// A weather-condition dynamic text layer normalizes its persisted rawValue
    /// ("wicon") to the engine's canonical "wcond" so `text_value` matches, and
    /// ships the localized condition table (so the label matches the baked
    /// glyphs). Regression for weather-condition text rendering nothing.
    func testWeatherConditionLayerNormalizedAndLocalized() throws {
        var design = WatchfaceDesign(name: "Wx")
        design.textLayers = [
            WatchfaceTextLayer(text: "", x: 120, y: 120, fontSize: 22, valueSource: .weatherCondition),
        ]
        let result = CustomFaceLayout.generate(for: design)
        let glyphs = try XCTUnwrap(result.fields["glyphs"] as? [[String: Any]])
        XCTAssertTrue(glyphs.contains { $0["src"] as? String == "wcond" },
                      "weather-condition src must normalize to wcond")
        let conds = try XCTUnwrap(result.fields["conds"] as? [String])
        XCTAssertEqual(conds, WatchfaceValueSource.weatherConditionNames())

        // chanceOfRain / uvIndex normalize too.
        var d2 = WatchfaceDesign(name: "Wx2")
        d2.textLayers = [
            WatchfaceTextLayer(text: "", x: 60, y: 60, fontSize: 20, valueSource: .chanceOfRain),
            WatchfaceTextLayer(text: "", x: 180, y: 60, fontSize: 20, valueSource: .uvIndex),
        ]
        let g2 = try XCTUnwrap(CustomFaceLayout.generate(for: d2).fields["glyphs"] as? [[String: Any]])
        XCTAssertTrue(g2.contains { $0["src"] as? String == "wrain" })
        XCTAssertTrue(g2.contains { $0["src"] as? String == "wuv" })
    }

    /// Localized condition labels stay within the glyph constraints (≤8 chars,
    /// non-empty, letters/digits only) and every letter is in the baked charset.
    func testWeatherConditionLabelsFitGlyphConstraints() {
        for id in ["fr_FR", "de_DE", "es_ES", "en_US"] {
            let names = WatchfaceValueSource.weatherConditionNames(locale: Locale(identifier: id))
            XCTAssertEqual(names.count, 7, "\(id)")
            XCTAssertTrue(names.allSatisfy { !$0.isEmpty && $0.count <= 8 }, "\(id): \(names)")
            XCTAssertTrue(names.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber } }, "\(id): \(names)")
        }
        XCTAssertEqual(WatchfaceValueSource.weatherConditionNames(locale: Locale(identifier: "fr_FR"))[0], "CLAIR")
    }

    /// The author-original customFace engine blob must be bundled.
    func testCustomFaceBlobBundled() throws {
        let url = Bundle(for: type(of: self)).url(
            forResource: "customFace", withExtension: "bin", subdirectory: "fossil_hr")
            ?? Bundle.main.url(
                forResource: "customFace", withExtension: "bin", subdirectory: "fossil_hr")
        XCTAssertNotNil(url, "customFace.bin not bundled")
    }

    /// Regression guard: a design with only static text layers must produce
    /// byte-identical container framing to what WappBuilder emitted before
    /// dynamic layers existed — no widgetText/text_layout leakage.
    func testStaticOnlyDesignUnaffectedByDynamicLayerSupport() throws {
        var design = WatchfaceDesign(name: "StaticOnly")
        design.textLayers = [WatchfaceTextLayer(text: "Hi", x: 120, y: 120)]
        let builder = WappBuilder(design: design)
        XCTAssertTrue(builder.dynamicTextLayers.isEmpty)
        let wapp = try builder.build()

        let offsetIcons = Int(wapp.u32LE(at: 12 + 16))
        let offsetLayout = Int(wapp.u32LE(at: 12 + 20))
        let offsetDisplayName = Int(wapp.u32LE(at: 12 + 24))
        let codeNames = sectionEntryNames(wapp, from: 88, to: offsetIcons)
        let iconNames = sectionEntryNames(wapp, from: offsetIcons, to: offsetLayout)
        let layoutNames = sectionEntryNames(wapp, from: offsetLayout, to: offsetDisplayName)

        XCTAssertFalse(codeNames.contains { $0.hasPrefix("widgetText") })
        XCTAssertFalse(iconNames.contains { $0.hasPrefix("t0") })
        XCTAssertFalse(layoutNames.contains("text_layout"))
    }


    func testCustomWidgetTextPayload() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JsonPayloads.customWidgetText(index: 1, upper: "UP", lower: "low")) as? [String: Any])
        let set = (json["push"] as? [String: Any])?["set"] as? [String: Any]
        XCTAssertEqual(set?["widgetCustom1._.config.upper_text"] as? String, "UP")
        XCTAssertEqual(set?["widgetCustom1._.config.lower_text"] as? String, "low")
    }

    func testFirmwareDetection() {
        var firmware = Data(count: 64)
        firmware[0] = 1
        for (i, byte) in [0x00, 0x20, 0x01, 0x00].enumerated() { firmware[8 + i] = UInt8(byte) }
        for (i, byte) in [0x00, 0x00, 0x02, 0x00].enumerated() { firmware[12 + i] = UInt8(byte) }
        firmware[20] = 2
        firmware[21] = 20
        XCTAssertTrue(FirmwareReader.isFirmware(firmware))
        XCTAssertEqual(FirmwareReader.version(firmware), "2.20")

        var notFirmware = firmware
        notFirmware[0] = 2
        XCTAssertFalse(FirmwareReader.isFirmware(notFirmware))
        // A .wapp is not firmware either.
        var wapp = Data(count: 64)
        wapp[0] = 0xFE; wapp[1] = 0x15; wapp[2] = 0x03
        XCTAssertFalse(FirmwareReader.isFirmware(wapp))
    }

    func testOneByteTextFieldsTruncateOnUTF8Boundaries() {
        let long = String(repeating: "é", count: 300)
        let bounded = long.nullTerminatedUTF8()
        XCTAssertLessThanOrEqual(bounded.count, Int(UInt8.max))
        XCTAssertEqual(bounded.last, 0)
        XCTAssertNotNil(String(data: bounded.dropLast(), encoding: .utf8))

        let play = NotificationPlayFile.encode(
            kind: .notification, flags: 0x02, packageCrc: 1,
            title: long, sender: long, message: long, messageId: 2)
        XCTAssertEqual(play.u8(at: 7), UInt8.max)
        XCTAssertEqual(play.u8(at: 8), UInt8.max)
        XCTAssertEqual(play.u8(at: 9), UInt8.max)

        let contact = QNotificationAlert(kind: .contact, identifier: long,
                                         displayName: long, degrees: 30)
        XCTAssertFalse(QNotificationFilterFile.encode([contact]).isEmpty)
    }

    func testWappContainerValidationRejectsCorruptionAndTrailingBytes() throws {
        let valid = try WappBuilder(design: WatchfaceDesign(name: "Validated")).build()
        XCTAssertTrue(WappReader.isValidContainer(valid))

        var corrupt = valid
        corrupt[corrupt.count - 1] ^= 0xFF
        XCTAssertFalse(WappReader.isValidContainer(corrupt))

        XCTAssertFalse(WappReader.isValidContainer(valid + Data([0])))
        XCTAssertFalse(WappReader.isValidContainer(Data(count: 91)))
    }

    // GB: TranslationsPutRequest.createPayload — locale + NUL, then
    // length-prefixed NUL-terminated string pairs (byte counts, UTF-8 safe).
    func testTranslationsEncoding() {
        let data = TranslationData(locale: "de_DE", items: [
            TranslationData.Item(original: "Steps", translated: "Schritte"),
        ]).encode()
        var expected = Data("de_DE".utf8) + Data([0x00])
        expected += Data([6, 0]) + Data("Steps".utf8) + Data([0x00])
        expected += Data([9, 0]) + Data("Schritte".utf8) + Data([0x00])
        XCTAssertEqual(data, expected)

        // Multi-byte UTF-8: lengths count bytes, not characters.
        let umlaut = TranslationData(locale: "de_DE", items: [
            TranslationData.Item(original: "On", translated: "Än"),
        ]).encode()
        XCTAssertEqual(Int(umlaut.u16LE(at: 11)), "Än".utf8.count + 1)
    }

    func testRLEEncoding() {
        let bytes: [UInt8] = [7, 7, 7, 0, 0, 3]
        let encoded = ImageEncoder.rleEncode(bytes)
        XCTAssertEqual(encoded, Data([3, 7, 2, 0, 1, 3]))
    }

    func testRLERunCap() {
        let bytes = [UInt8](repeating: 9, count: 300)
        let encoded = ImageEncoder.rleEncode(bytes)
        XCTAssertEqual(encoded, Data([255, 9, 45, 9]))
    }
}

final class ActivityParserTests: XCTestCase {
    func testEveryInvalidPrefixOfValidHrFixtureThrows() throws {
        var file = Data(count: 64)
        file[2] = 22
        let timestamp: UInt32 = 1_700_000_000
        for index in 0..<4 {
            file[8 + index] = UInt8((timestamp >> (8 * UInt32(index))) & 0xFF)
        }
        // One complete CE activity sample, followed by the four bytes that
        // belong to the already-validated outer container CRC.
        let record: [UInt8] = [0xCE, 0x08, 0x01, 0x02, 24, 2, 70, 0x45]
        for (index, byte) in record.enumerated() { file[52 + index] = byte }

        let parser = try ActivityParser.parse(file)
        XCTAssertTrue(parser.isComplete)
        XCTAssertEqual(parser.samples.count, 1)
        for length in 0..<file.count where length != 56 && length != 48 {
            XCTAssertThrowsError(try ActivityParser.parse(file.prefix(length)),
                                 "truncated valid HR fixture parsed at length \(length)")
        }
        // 56 bytes (52-byte header/marker-stream start + 4-byte trailing CRC,
        // zero records) is the minimum valid file, not a truncation of this
        // one — a watch with no samples yet produces exactly this file.
        let empty = try ActivityParser.parse(file.prefix(56))
        XCTAssertTrue(empty.isComplete)
        XCTAssertEqual(empty.samples.count, 0)
        // 48 bytes cuts off before offset 52, the earliest point an HR file
        // is distinguishable from a no-HR one — indistinguishable from a
        // genuinely empty no-HR file (44-byte header + 4-byte CRC), so it
        // parses rather than throws. Real hardware can't produce a shorter-
        // than-52 truncated HR download either: the transport CRC32 already
        // rejects a short transfer before this parser ever sees it.
        let ambiguous = try ActivityParser.parse(file.prefix(48))
        XCTAssertTrue(ambiguous.isComplete)
        XCTAssertEqual(ambiguous.samples.count, 0)
    }

    /// Builds a synthetic no-HR-variant activity file: version 22, timestamp
    /// sync at 34, three 4-byte records from offset 44.
    func testNoHrVariantParsing() throws {
        var file = Data(count: 60)
        file[2] = 22                                   // version (u16 LE)
        let timestamp: UInt32 = 1_700_000_000
        // The no-HR file has NO container length at offset 8 — that offset
        // holds a Unix timestamp (byte-identical to the 0xE2 0x04 block at
        // offset 34), confirmed by a real Q Grant dump. Set it as a timestamp
        // to guard against reintroducing an HR-style length assumption here.
        for i in 0..<4 { file[8 + i] = UInt8((timestamp >> (8 * UInt32(i))) & 0xFF) }
        for i in 0..<4 { file[34 + i] = UInt8((timestamp >> (8 * UInt32(i))) & 0xFF) }
        // record: varLo (even => steps = lo & 0xFE), varHi, 0xFF, flags
        let records: [[UInt8]] = [
            [24, 2, 0xFF, 0x45],   // 24 steps, active, 5 kcal
            [0, 0, 0xFF, 0x02],    // idle, 2 kcal
            [50, 1, 0xFF, 0x00],   // 50 steps
        ]
        for (index, record) in records.enumerated() {
            for (offset, byte) in record.enumerated() {
                file[44 + index * 4 + offset] = byte
            }
        }
        // offset 52 must not be an HR marker: it's records[2][0] = 50 ✓

        let parser = try ActivityParser.parse(file)
        XCTAssertEqual(parser.samples.count, 3)
        XCTAssertEqual(parser.samples[0].timestamp, Int(timestamp))
        XCTAssertEqual(parser.samples[0].stepCount, 24)
        XCTAssertEqual(parser.samples[0].calories, 5)
        XCTAssertTrue(parser.samples[0].isActive)
        XCTAssertEqual(parser.samples[1].timestamp, Int(timestamp) + 60)
        XCTAssertFalse(parser.samples[1].isActive)
        XCTAssertEqual(parser.samples[2].stepCount, 50)
        for length in 0..<file.count where length != 56 && length != 48 && length != 52 {
            XCTAssertThrowsError(try ActivityParser.parse(file.prefix(length)),
                                 "truncated valid no-HR fixture parsed at length \(length)")
        }
        // 56 bytes lands exactly on the second record's end (44 + 2*4 + 4
        // trailing CRC) — a clean 2-record file, not a truncation of the
        // 3-record one.
        let partial = try ActivityParser.parse(file.prefix(56))
        XCTAssertTrue(partial.isComplete)
        XCTAssertEqual(partial.samples.count, 2)
        // 48 (44-byte header + 4-byte CRC, zero records) and 52 (+ one clean
        // record) are likewise complete no-HR files in their own right, not
        // truncations — a real Q Grant capture with a single record is
        // exactly 52 bytes (see ActivityParser's minimum-length comment).
        let empty = try ActivityParser.parse(file.prefix(48))
        XCTAssertTrue(empty.isComplete)
        XCTAssertEqual(empty.samples.count, 0)
        let oneRecord = try ActivityParser.parse(file.prefix(52))
        XCTAssertTrue(oneRecord.isComplete)
        XCTAssertEqual(oneRecord.samples.count, 1)
    }

    func testRejectsWrongVersion() {
        var file = Data(count: 60)
        file[2] = 21
        XCTAssertThrowsError(try ActivityParser.parse(file))
    }

    /// 0xE0 workout summary: 14 TLVs with GB's attribute ids — duration (2),
    /// steps (4), distance in cm (5), calories (6), avg/max HR (7/8), type
    /// (9); all-0xFF payloads are "not recorded" and must be skipped.
    func testWorkoutSummaryDetailParsing() throws {
        var file = Data(count: 53)
        file[2] = 22                                     // version
        let timestamp: UInt32 = 1_700_000_000
        for i in 0..<4 { file[8 + i] = UInt8((timestamp >> (8 * UInt32(i))) & 0xFF) }
        file[52] = 0xE0                                  // workout marker

        func tlv(_ id: UInt8, _ payload: [UInt8]) -> Data {
            Data([id, UInt8(payload.count)] + payload)
        }
        func u32(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
        }
        file.append(tlv(2, u32(600)))                    // 10 min
        file.append(tlv(4, [0xFF, 0xFF, 0xFF, 0xFF]))    // steps not recorded
        file.append(tlv(5, u32(250_000)))                // 2500.00 m
        file.append(tlv(6, u32(150)))                    // kcal
        file.append(tlv(7, [132]))                       // avg HR
        file.append(tlv(8, [165]))                       // max HR
        file.append(tlv(9, [0x01]))                      // Running
        for id in 10...16 { file.append(tlv(UInt8(id), [0xFF])) }   // 7 fillers
        file.append(0x00)                                // trailing pad
        file.append(Data(count: 4))                      // container CRC trailer

        let parser = try ActivityParser.parse(file)
        XCTAssertEqual(parser.workouts.count, 1)
        let workout = try XCTUnwrap(parser.workouts.first)
        XCTAssertEqual(workout.kind, "Running")
        XCTAssertEqual(workout.startTimestamp, Int(timestamp) - 600)
        XCTAssertEqual(workout.endTimestamp, Int(timestamp))
        XCTAssertNil(workout.steps)                      // all-0xFF skipped
        XCTAssertEqual(workout.distanceMeters, 2500)
        XCTAssertEqual(workout.calories, 150)
        XCTAssertEqual(workout.averageHeartRate, 132)
        XCTAssertEqual(workout.maxHeartRate, 165)
    }
}

final class FitnessConfigTests: XCTestCase {
    func testWorkoutDetectionPayloadDefaults() {
        // All detection off => the unmodified 24-byte template + 6 zero bytes.
        let payload = ConfigItem.fitnessDetection(WorkoutDetectionSettings()).payload
        XCTAssertEqual(payload.count, 30)
        XCTAssertEqual(payload.prefix(6), Data([0x01, 0x00, 0x03, 0x01, 0x01, 0x05]))
        XCTAssertEqual(payload.suffix(6), Data(count: 6))
    }

    func testWorkoutDetectionPayloadRunningEnabled() {
        var settings = WorkoutDetectionSettings()
        settings.running.recognize = true
        settings.running.askFirst = true
        settings.running.minutes = 7
        let payload = ConfigItem.fitnessDetection(settings).payload
        XCTAssertEqual(payload.u8(at: 1), 0x03)   // recognize | ask
        XCTAssertEqual(payload.u8(at: 2), 7)
        XCTAssertEqual(payload.u8(at: 7), 0x00)   // biking untouched
    }

    func testInactivityPayload() {
        let item = ConfigItem.inactivityWarning(from: (8, 30), until: (20, 0), minutes: 60, enabled: true)
        XCTAssertEqual(item.payload, Data([8, 30, 20, 0, 60, 1]))
        XCTAssertEqual(item.id, 0x09)
    }
}

final class AppListParserTests: XCTestCase {
    func testParseSingleEntry() {
        var file = Data(count: 12)                     // 12-byte header
        let name = "timerApp"
        var entry = Data()
        entry.appendUInt16LE(UInt16(2 + name.count + 1 + 1 + 4 + 2 + 2))
        entry.append(0x00)
        entry.append(UInt8(name.count + 1))
        entry.append(name.data(using: .utf8)!)
        entry.append(0x00)
        entry.append(0x42)                             // handle
        entry.appendUInt32LE(0xDEAD_BEEF)              // hash
        entry.append(contentsOf: [2, 5])               // version 2.5
        entry.append(contentsOf: [0, 0])               // unknown
        file.append(entry)
        file.append(Data(count: 4))                    // trailing CRC

        let apps = InstalledApp.parseList(fromRawFile: file)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].name, "timerApp")
        XCTAssertEqual(apps[0].version, "2.5")
        XCTAssertEqual(apps[0].handle, 0x42)
        XCTAssertEqual(apps[0].fullHandle, 0x1542)
        XCTAssertFalse(apps[0].isWatchface)
    }
}

final class WeatherPayloadTests: XCTestCase {
    private func sampleSnapshot() -> WeatherSnapshot {
        WeatherSnapshot(
            unit: "c", city: "Paris", temp: 21, high: 24, low: 15, rain: 30, uv: 5,
            message: "Rain", condId: 5,
            forecastDay: [.init(hour: 14, condId: 5, temp: 20), .init(hour: 15, condId: 5, temp: 19)],
            forecastWeek: [.init(day: "Mon", condId: 5, high: 24, low: 15)])
    }

    private func decodeRes(_ data: Data) -> (id: Int?, set: [String: Any]) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let res = root?["res"] as? [String: Any] ?? [:]
        return (res["id"] as? Int, res["set"] as? [String: Any] ?? [:])
    }

    func testWeatherInfoResponseShape() {
        let (id, set) = decodeRes(JsonPayloads.weatherInfoResponse(id: 7, snapshot: sampleSnapshot()))
        XCTAssertEqual(id, 7)
        let info = set["weatherInfo"] as? [String: Any]
        XCTAssertEqual(info?["unit"] as? String, "c")
        XCTAssertEqual(info?["temp"] as? Int, 21)
        XCTAssertEqual(info?["cond_id"] as? Int, 5)
        XCTAssertNotNil(info?["alive"])
    }

    func testWeatherAppResponseShape() {
        let (_, set) = decodeRes(JsonPayloads.weatherAppResponse(id: 3, snapshot: sampleSnapshot()))
        let locations = set["weatherApp._.config.locations"] as? [[String: Any]]
        XCTAssertEqual(locations?.count, 1)
        let loc = locations?.first
        XCTAssertEqual(loc?["city"] as? String, "Paris")
        XCTAssertEqual(loc?["high"] as? Int, 24)
        XCTAssertEqual(loc?["low"] as? Int, 15)
        XCTAssertEqual(loc?["rain"] as? Int, 30)
        XCTAssertEqual(loc?["uv"] as? Int, 5)
        let forecastDay = loc?["forecast_day"] as? [[String: Any]]
        XCTAssertEqual(forecastDay?.count, 2)
        XCTAssertEqual(forecastDay?.first?["hour"] as? Int, 14)
        let forecastWeek = loc?["forecast_week"] as? [[String: Any]]
        XCTAssertEqual(forecastWeek?.first?["day"] as? String, "Mon")
    }

    func testRainWidgetResponseHasNoId() {
        let (id, set) = decodeRes(JsonPayloads.rainWidgetResponse(rainPercent: 42))
        XCTAssertNil(id)
        let widget = set["widgetChanceOfRain._.config.info"] as? [String: Any]
        XCTAssertEqual(widget?["rain"] as? Int, 42)
    }

    func testUVWidgetResponseHasNoId() {
        let (id, set) = decodeRes(JsonPayloads.uvWidgetResponse(uv: 8))
        XCTAssertNil(id)
        let widget = set["widgetUV._.config.info"] as? [String: Any]
        XCTAssertEqual(widget?["uv"] as? Int, 8)
    }
}

final class WeatherConditionMappingTests: XCTestCase {
    func testClearMapsByDaylight() {
        XCTAssertEqual(WeatherProvider.condId(for: .clear, isDaylight: true), 0)
        XCTAssertEqual(WeatherProvider.condId(for: .clear, isDaylight: false), 1)
        XCTAssertEqual(WeatherProvider.condId(for: .mostlyClear, isDaylight: true), 0)
    }

    func testPartlyCloudyMapsByDaylight() {
        XCTAssertEqual(WeatherProvider.condId(for: .partlyCloudy, isDaylight: true), 3)
        XCTAssertEqual(WeatherProvider.condId(for: .mostlyCloudy, isDaylight: false), 4)
    }

    func testCloudyGroup() {
        XCTAssertEqual(WeatherProvider.condId(for: .cloudy, isDaylight: true), 2)
        XCTAssertEqual(WeatherProvider.condId(for: .foggy, isDaylight: true), 2)
    }

    func testRainGroup() {
        XCTAssertEqual(WeatherProvider.condId(for: .rain, isDaylight: true), 5)
        XCTAssertEqual(WeatherProvider.condId(for: .drizzle, isDaylight: false), 5)
    }

    func testSnowGroup() {
        XCTAssertEqual(WeatherProvider.condId(for: .snow, isDaylight: true), 6)
        XCTAssertEqual(WeatherProvider.condId(for: .blizzard, isDaylight: true), 6)
    }

    func testThunderstormGroup() {
        XCTAssertEqual(WeatherProvider.condId(for: .thunderstorms, isDaylight: true), 8)
        XCTAssertEqual(WeatherProvider.condId(for: .isolatedThunderstorms, isDaylight: true), 8)
    }

    func testWindyGroup() {
        XCTAssertEqual(WeatherProvider.condId(for: .windy, isDaylight: true), 10)
        XCTAssertEqual(WeatherProvider.condId(for: .breezy, isDaylight: true), 10)
    }
}

final class CalendarPayloadTests: XCTestCase {
    func testTruncationKeepsLimit() {
        let long = String(repeating: "a", count: 60)
        XCTAssertEqual(CalendarSync.truncate(long).count, 40)
        XCTAssertEqual(CalendarSync.truncate("short"), "short")
    }

    func testStableIdIsDeterministic() {
        let a = CalendarSync.stableId(for: "event-123")
        let b = CalendarSync.stableId(for: "event-123")
        XCTAssertEqual(a, b)
        XCTAssertGreaterThanOrEqual(a, 0)   // sign bit cleared
    }

    func testStableIdDiffersForDifferentInput() {
        XCTAssertNotEqual(CalendarSync.stableId(for: "event-123"), CalendarSync.stableId(for: "event-124"))
    }

    func testEventsPushShape() {
        let events = [
            CalendarEventPayload(id: 1, title: "Standup", desc: "", start: 1000, end: 1600, reminders: [900]),
            CalendarEventPayload(id: 2, title: "Lunch", desc: "with team", start: 2000, end: 2600, reminders: []),
        ]
        let payload = JsonPayloads.calendarEventsPush(events)
        let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let res = root?["res"] as? [String: Any]
        XCTAssertNil(res?["id"])   // fire-and-forget push, no req/ack cycle
        let set = res?["set"] as? [String: Any]
        let items = set?["customWatchFace._.config.events"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?.first?["title"] as? String, "Standup")
        XCTAssertEqual(items?.first?["reminders"] as? [Int], [900])
    }

    func testDedupeKeyStableForIdenticalInputChangesWithContent() {
        // JSONSerialization's dictionary key order is not guaranteed stable
        // across calls (confirmed empirically), so the dedupe key must be
        // computed from the structured events, not the serialized bytes.
        let events = [
            CalendarEventPayload(id: 1, title: "Standup", desc: "", start: 1000, end: 1600, reminders: [900]),
            CalendarEventPayload(id: 2, title: "Lunch", desc: "with team", start: 2000, end: 2600, reminders: []),
        ]
        XCTAssertEqual(CalendarSync.dedupeKey(for: events), CalendarSync.dedupeKey(for: events))
        XCTAssertNotEqual(CalendarSync.dedupeKey(for: events), CalendarSync.dedupeKey(for: [events[0]]))
        XCTAssertNotEqual(CalendarSync.dedupeKey(for: events), CalendarSync.dedupeKey(for: []))
    }
}

final class ButtonConfigTests: XCTestCase {
    private func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func testButtonConfigShape() {
        let assignments = [
            ButtonAssignment(event: "top_short_press_release", appName: "weatherApp"),
            ButtonAssignment(event: "bottom_hold", appName: "musicApp"),
        ]
        let root = decode(JsonPayloads.buttonConfig(assignments))
        let set = (root?["push"] as? [String: Any])?["set"] as? [String: Any]
        let items = set?["master._.config.buttons"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?.first?["button_evt"] as? String, "top_short_press_release")
        XCTAssertEqual(items?.first?["name"] as? String, "weatherApp")
        XCTAssertEqual(items?.last?["button_evt"] as? String, "bottom_hold")
    }

    func testFirmwareVersionParsing() {
        XCTAssertTrue(FirmwareVersion("DN1.0.2.20")!.atLeast(2, 19))
        XCTAssertFalse(FirmwareVersion("DN1.0.2.18")!.atLeast(2, 19))
        XCTAssertTrue(FirmwareVersion("DN1.0.3.0")!.atLeast(3, 0))
        XCTAssertFalse(FirmwareVersion("DN1.0.2.20")!.atLeast(3, 0))
        XCTAssertNil(FirmwareVersion("garbage"))
        // Real firmware strings carry a trailing suffix (see WatchKindTests);
        // it must not be mistaken for extra version components.
        XCTAssertTrue(FirmwareVersion("DN1.0.2.20r.v5")!.atLeast(2, 20))
        XCTAssertFalse(FirmwareVersion("DN1.0.2.20r.v5")!.atLeast(2, 22))
    }

    private static let allApps: Set<String> = ["weatherApp", "launcherApp", "musicApp", "commuteApp", "stopwatchApp"]

    func testFullSetSentWithDefaults() {
        // No user picks: GB always sends the complete slot set, never a sparse
        // one (the omitted-event-goes-dead bug this fixes). Each short slot
        // emits both event names → 3 short × 2 + 3 long × 1 = 9 on FW ≥ 3.0.
        let a = ButtonConfig.assignments(userSelections: [], installed: Self.allApps,
                                         firmware: FirmwareVersion("DN1.0.3.0"))
        XCTAssertEqual(a.count, 9)
        // Both short-press event names are sent so it works on any firmware.
        XCTAssertTrue(a.contains(ButtonAssignment(event: "top_short_press_release", appName: "weatherApp")))
        XCTAssertTrue(a.contains(ButtonAssignment(event: "top_single_click", appName: "weatherApp")))
        // Middle short-press defaults to the launcher (restores select/menu).
        XCTAssertTrue(a.contains(ButtonAssignment(event: "middle_short_press_release", appName: "launcherApp")))
        XCTAssertTrue(a.contains(ButtonAssignment(event: "middle_single_click", appName: "launcherApp")))
        XCTAssertTrue(a.contains(ButtonAssignment(event: "middle_hold", appName: "launcherApp")))
    }

    func testUserPickOverridesSlotDefault() {
        let picks = [ButtonSelection(button: .bottom, press: .short, appName: "stopwatchApp")]
        let a = ButtonConfig.assignments(userSelections: picks, installed: Self.allApps, firmware: nil)
        XCTAssertTrue(a.contains(ButtonAssignment(event: "bottom_short_press_release", appName: "stopwatchApp")))
        XCTAssertFalse(a.contains { $0.event == "bottom_short_press_release" && $0.appName == "musicApp" })
    }

    func testUninstalledAppsDropped() {
        // Only musicApp installed → only the bottom slots (music) survive.
        let a = ButtonConfig.assignments(userSelections: [], installed: ["musicApp"], firmware: nil)
        XCTAssertEqual(Set(a.map(\.appName)), ["musicApp"])
        XCTAssertTrue(a.contains { $0.event == "bottom_short_press_release" })
        XCTAssertFalse(a.contains { $0.event == "middle_short_press_release" })
    }

    func testFirmwareGatesMiddleHoldOnly() {
        // Only middle_hold is firmware-gated; both short-press names always ship.
        let mid = ButtonConfig.assignments(userSelections: [], installed: Self.allApps,
                                           firmware: FirmwareVersion("DN1.0.2.20"))
        XCTAssertFalse(mid.contains { $0.event == "middle_hold" })   // FW < 3.0
        XCTAssertTrue(mid.contains { $0.event == "middle_short_press_release" })
        XCTAssertTrue(mid.contains { $0.event == "middle_single_click" })

        // Unknown firmware still sends middle_hold and both short names.
        let unknown = ButtonConfig.assignments(userSelections: [], installed: Self.allApps, firmware: nil)
        XCTAssertTrue(unknown.contains { $0.event == "middle_short_press_release" })
        XCTAssertTrue(unknown.contains { $0.event == "middle_single_click" })
        XCTAssertTrue(unknown.contains { $0.event == "middle_hold" })
    }

    func testWorkoutAppAlwaysAvailable() {
        // workoutApp lives in firmware, so it's assignable with nothing installed.
        let picks = [ButtonSelection(button: .top, press: .short, appName: "workoutApp")]
        let a = ButtonConfig.assignments(userSelections: picks, installed: [], firmware: nil)
        XCTAssertTrue(a.contains(ButtonAssignment(event: "top_short_press_release", appName: "workoutApp")))
    }
}

final class WappMetadataTests: XCTestCase {
    func testHomeAssistantAppMetadata() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "homeAssistantApp", withExtension: "wapp",
                                                subdirectory: "fossil_hr"),
                                "homeAssistantApp.wapp must be bundled")
        let data = try Data(contentsOf: url)
        let meta = try XCTUnwrap(WappReader.metadata(fromWapp: data))
        XCTAssertEqual(meta.name, "Home Assistant")
        XCTAssertFalse(meta.isWatchface)
    }
}

final class TextLayerTests: XCTestCase {
    func testOldDesignJSONStillDecodes() throws {
        // Saved by a version that predates text layers: no textLayers key.
        let json = """
        [{"id":"11111111-2222-3333-4444-555555555555","name":"Old",
          "widgets":[{"id":"99999999-2222-3333-4444-555555555555","type":"widgetDate",
                      "x":120,"y":58,"color":0,"background":""}]}]
        """
        let designs = try JSONDecoder().decode([WatchfaceDesign].self, from: Data(json.utf8))
        XCTAssertEqual(designs.count, 1)
        XCTAssertEqual(designs[0].widgets.count, 1)
        XCTAssertTrue(designs[0].textLayers.isEmpty)
    }

    /// Saved by a version that predates dynamic values: text layers exist
    /// but carry no valueSource key.
    func testOldTextLayerJSONStillDecodesAsStatic() throws {
        let json = """
        {"id":"11111111-2222-3333-4444-555555555555","text":"Hi","x":120,"y":120,
         "fontFamily":"","bold":false,"fontSize":24,"rotation":0,"shade":3}
        """
        let layer = try JSONDecoder().decode(WatchfaceTextLayer.self, from: Data(json.utf8))
        XCTAssertNil(layer.valueSource)
    }

    func testDesignRoundTripKeepsTextLayers() throws {
        var design = WatchfaceDesign(name: "Layered")
        design.textLayers = [WatchfaceTextLayer(text: "12", x: 60, y: 180,
                                                fontFamily: "Courier New", bold: true,
                                                fontSize: 40, rotation: -45, shade: 2)]
        let decoded = try JSONDecoder().decode(WatchfaceDesign.self,
                                               from: JSONEncoder().encode(design))
        XCTAssertEqual(decoded, design)
    }

    func testCompositeWithoutLayersReturnsBackgroundUntouched() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
        let black = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        }
        XCTAssertEqual(TextLayerRenderer.composite(background: black, layers: []), black)
        // Whitespace-only layers draw nothing but still go through the
        // compositing path; the canvas must stay fully black.
        let empty = WatchfaceTextLayer(text: "")
        let out = TextLayerRenderer.composite(background: black, layers: [empty])
        let pixels = ImageEncoder.pixels(from: out, width: 240, height: 240)!
        XCTAssertEqual((0..<240 * 240).map { pixels.gray(atIndex: $0) }.max(), 0)
    }

    func testCompositeBakesTextIntoBackground() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
        let black = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        }
        let layer = WatchfaceTextLayer(text: "888", x: 120, y: 120, fontSize: 60, shade: 3)
        let out = TextLayerRenderer.composite(background: black, layers: [layer])
        XCTAssertEqual(out.size.width, TextLayerRenderer.canvasSide)

        let pixels = ImageEncoder.pixels(from: out, width: 240, height: 240)!
        var litInCenter = 0
        var litInTopLeftCorner = 0
        for y in 0..<240 {
            for x in 0..<240 where pixels.gray(atIndex: y * 240 + x) > 128 {
                if abs(x - 120) < 50, abs(y - 120) < 30 { litInCenter += 1 }
                if x < 40, y < 40 { litInTopLeftCorner += 1 }
            }
        }
        XCTAssertGreaterThan(litInCenter, 100, "text must appear around its center point")
        XCTAssertEqual(litInTopLeftCorner, 0, "no stray drawing away from the layer")
    }

    func testCompositeRotationDrawsVertically() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
        let black = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        }
        // A long string rotated 90°: lit pixels must span far more rows than
        // columns around the anchor.
        let layer = WatchfaceTextLayer(text: "MMMMMMMM", x: 120, y: 120,
                                       fontSize: 30, rotation: 90, shade: 3)
        let out = TextLayerRenderer.composite(background: black, layers: [layer])
        let pixels = ImageEncoder.pixels(from: out, width: 240, height: 240)!
        var minX = 240, maxX = 0, minY = 240, maxY = 0
        for y in 0..<240 {
            for x in 0..<240 where pixels.gray(atIndex: y * 240 + x) > 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(maxY - minY, (maxX - minX) * 2)
    }

    /// Dynamic layers are drawn by the watch, never baked on the phone —
    /// even with non-empty text, compositing must leave the canvas blank.
    func testCompositeSkipsDynamicLayers() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
        let black = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        }
        let layer = WatchfaceTextLayer(text: "888", x: 120, y: 120, fontSize: 60, shade: 3,
                                       valueSource: .steps)
        XCTAssertEqual(TextLayerRenderer.composite(background: black, layers: [layer]), black)
    }
}

final class GlyphAtlasTests: XCTestCase {
    func testChecksetsPerSource() {
        XCTAssertEqual(Set(WatchfaceValueSource.steps.charset), Set("0123456789,"))
        XCTAssertEqual(Set(WatchfaceValueSource.heartRate.charset), Set("0123456789-"))
        XCTAssertEqual(Set(WatchfaceValueSource.battery.charset), Set("0123456789%"))
        XCTAssertEqual(Set(WatchfaceValueSource.time.charset), Set("0123456789:"))
        XCTAssertEqual(Set(WatchfaceValueSource.date.charset), Set("0123456789"))
        // Every letter of the current locale's day names plus the English
        // fallback table's letters (legible fallback if data.days is lost).
        XCTAssertEqual(Set(WatchfaceValueSource.weekday.charset),
                       Set(WatchfaceValueSource.weekdayNames().joined() + "SUNMONTUEWEDTHUFRISAT"))
    }

    func testLocalizedWeekdayNames() {
        // Sunday-first, uppercased, diacritics folded, punctuation stripped
        // — the exact strings shipped in data.days and baked as glyphs.
        XCTAssertEqual(WatchfaceValueSource.weekdayNames(locale: Locale(identifier: "en_US")),
                       ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"])
        XCTAssertEqual(WatchfaceValueSource.weekdayNames(locale: Locale(identifier: "fr_FR")),
                       ["DIM", "LUN", "MAR", "MER", "JEU", "VEN", "SAM"])
        // Spanish "mié." (Sunday-first index 3) exercises the diacritic fold.
        XCTAssertEqual(WatchfaceValueSource.weekdayNames(locale: Locale(identifier: "es_ES"))[3], "MIE")
    }

    func testWeekdayNamesFitCharsetAndBox() {
        // The names shipped to the watch must stay in lockstep with the
        // baked charset and the bounding-box character count.
        let names = WatchfaceValueSource.weekdayNames()
        XCTAssertEqual(names.count, 7)
        let charset = Set(WatchfaceValueSource.weekday.charset)
        for name in names {
            XCTAssertFalse(name.isEmpty)
            XCTAssertTrue(name.allSatisfy { charset.contains($0) }, name)
            XCTAssertLessThanOrEqual(name.count, WatchfaceValueSource.weekday.maxCharacters)
            XCTAssertLessThanOrEqual(name.count, 8)   // text_layout slot count
        }
    }

    func testUniformCellDimensions() throws {
        let layer = WatchfaceTextLayer(text: "", x: 0, y: 0, fontSize: 40, valueSource: .steps)
        let cell = try XCTUnwrap(GlyphAtlas.cells(for: layer, layerIndex: 0))
        XCTAssertEqual(cell.glyphs.count, WatchfaceValueSource.steps.charset.count)
        for glyph in cell.glyphs {
            // RLE header: [width][height][pairs...][FF FF] (firmware order,
            // proven by the non-square stock icons — see ImageEncoder).
            // Every image is baked at the uniform cell box — unequal
            // sibling image dimensions shear on the watch ("MER" → "777");
            // only the advance (Glyph.width, the pen step) is proportional.
            XCTAssertEqual(Int(glyph.rle[glyph.rle.startIndex]), cell.width)
            XCTAssertEqual(Int(glyph.rle[glyph.rle.startIndex + 1]), cell.height)
            XCTAssertEqual(glyph.rle.suffix(2), Data([0xFF, 0xFF]))
            XCTAssertGreaterThan(glyph.width, 0)
            XCTAssertLessThanOrEqual(glyph.width, cell.width)
        }
        XCTAssertEqual(cell.width, cell.glyphs.map(\.width).max())
        XCTAssertGreaterThan(cell.height, 0)
        // Advances stay proportional — the comma is narrower than the
        // digits in any real font.
        XCTAssertLessThan(try XCTUnwrap(cell.glyphs.first { $0.code == "c" }).width,
                          try XCTUnwrap(cell.glyphs.first { $0.code == "0" }).width)
    }

    func testStaticLayerHasNoGlyphAtlas() {
        let layer = WatchfaceTextLayer(text: "Hi", x: 0, y: 0)
        XCTAssertNil(GlyphAtlas.cells(for: layer, layerIndex: 0))
        XCTAssertEqual(GlyphAtlas.totalBytes(for: layer, layerIndex: 0), 0)
    }

    /// Asset names stay well under the ~29-byte icon-name limit
    /// (WatchfaceWidget.backgroundRLEName) for every layer index the editor
    /// allows (cap: 2 dynamic layers).
    func testGlyphNamesStayShort() throws {
        for index in 0..<2 {
            let layer = WatchfaceTextLayer(text: "", x: 0, y: 0, valueSource: .time)
            let cell = try XCTUnwrap(GlyphAtlas.cells(for: layer, layerIndex: index))
            for glyph in cell.glyphs {
                XCTAssertLessThan(glyph.name.utf8.count, 29)
            }
        }
        XCTAssertEqual(GlyphAtlas.assetCode(for: ","), "c")
        XCTAssertEqual(GlyphAtlas.assetCode(for: "%"), "p")
        XCTAssertEqual(GlyphAtlas.assetCode(for: ":"), "n")
        XCTAssertEqual(GlyphAtlas.assetCode(for: "/"), "s")
        XCTAssertEqual(GlyphAtlas.assetCode(for: "-"), "d")
        XCTAssertEqual(GlyphAtlas.assetCode(for: "7"), "7")
    }
}
