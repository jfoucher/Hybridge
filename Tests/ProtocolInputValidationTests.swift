import XCTest
@testable import Hybridge

final class ProtocolInputValidationTests: XCTestCase {
    func testBundleIDValidationRejectsMalformedAndOversizedValues() {
        XCTAssertEqual(ProtocolInputValidation.normalizedBundleID(" com.example.app \n"),
                       "com.example.app")
        for invalid in ["", "single", ".example", "com..app", "com.exämple.app",
                        "com.example.app!", String(repeating: "a", count: 64) + ".app"] {
            XCTAssertNil(ProtocolInputValidation.normalizedBundleID(invalid), invalid)
        }
        XCTAssertNil(ProtocolInputValidation.normalizedBundleID(
            "com." + String(repeating: "a", count: 250)))
    }

    func testDisplayNameAndPayloadStringsRespectBoundariesWithUnicode() {
        let name = ProtocolInputValidation.displayName(
            String(repeating: "👩🏽‍💻", count: 100), fallback: "Fallback")
        XCTAssertLessThanOrEqual(name.count, ProtocolInputValidation.maximumDisplayNameCharacters)

        let encoded = NotificationPlayFile.encode(
            kind: .notification, packageName: "com.example.app",
            sender: String(repeating: "é", count: 300),
            message: String(repeating: "🙂", count: 300))
        // The three one-byte string lengths live after the fixed header.
        XCTAssertEqual(encoded.u8(at: 8), 255) // 254 UTF-8 bytes + NUL
        XCTAssertEqual(encoded.u8(at: 9), 253) // 252 UTF-8 bytes + NUL
    }

    func testNotificationIconDimensionsClampWithoutIntegerTrap() {
        let icon = WatchNotificationIcon(
            name: String(repeating: "n", count: 400),
            width: Int.max, height: -10, rleData: Data([1, 0]))
        let block = icon.block
        let nameLength = min(400, 240)
        XCTAssertEqual(block.u8(at: 2 + nameLength + 1), UInt8(WatchNotificationIcon.maxSide))
        XCTAssertEqual(block.u8(at: 2 + nameLength + 2), 0)
    }
}
