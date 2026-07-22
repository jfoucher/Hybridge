import XCTest
@testable import Hybridge

/// §5.2 regression: a malformed or truncated activity file must never trap.
/// A trap here is unrecoverable in the field — `syncActivity` deletes the
/// watch's copy only after a *successful* parse+merge, so a file that crashes
/// the parser is re-downloaded and re-crashes on every connect, forever, with
/// no user way out but deleting the app. The parser must therefore either
/// return a result or throw `ParseError`, never crash, on any input.
///
/// These tests reaching completion *is* the assertion: a trap would tear down
/// the test process.
final class ActivityParserFuzzTests: XCTestCase {

    private func attempt(_ data: Data) {
        // Success or a thrown ParseError are both fine; a trap is not.
        _ = try? ActivityParser.parse(data)
    }

    func testFullyRandomInputNeverTraps() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let length = Int.random(in: 0...400, using: &rng)
            var data = Data(count: length)
            for i in 0..<length { data[i] = UInt8.random(in: 0...255, using: &rng) }
            attempt(data)
        }
    }

    func testValidHeaderRandomBodyNeverTraps() {
        // A well-formed-looking header (version 22) steers execution into the
        // real parse branches, then feeds them random body bytes — the case
        // most likely to reach a length-sensitive read.
        let markers: [UInt8] = [0xCE, 0xC2, 0xE2, 0xE0, 0xDD, 0xD6, 0xCB, 0xCC, 0xCF, 0x00, 0xFF]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let length = Int.random(in: 57...400, using: &rng)
            var data = Data(count: length)
            for i in 0..<length { data[i] = UInt8.random(in: 0...255, using: &rng) }
            data[2] = 22; data[3] = 0                    // version 22 (LE)
            data[52] = markers.randomElement(using: &rng)!  // pick HR / no-HR branch
            attempt(data)
        }
    }

    func testEveryTruncationOfASyntheticFileNeverTraps() {
        // Build one plausible HR-variant buffer, then feed every prefix of it:
        // the classic way a partial BLE download reaches the parser.
        var data = Data(count: 120)
        data[2] = 22
        data[52] = 0xCE
        for i in 53..<120 { data[i] = UInt8(i & 0xFF) }
        for prefix in 0...data.count {
            attempt(data.prefix(prefix))
        }
    }

    func testTinyInputsThrowRatherThanTrap() {
        for length in 0...56 {
            var data = Data(count: length)
            if length > 3 { data[2] = 22 }
            XCTAssertThrowsError(try ActivityParser.parse(data),
                                 "a sub-header-length file must throw, not parse")
        }
    }
}
