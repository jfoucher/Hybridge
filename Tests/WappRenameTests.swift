import XCTest
@testable import Hybridge

/// `WappBuilder.renamingIdentifier` is byte surgery on a container the watch
/// will execute: the identifier's length shifts every absolute section offset,
/// the payload length and the trailing CRC32C. A container that survives
/// `isValidContainer` but has a stale offset installs broken code — which is
/// the exact situation the rescue exists to get out of.
final class WappRenameTests: XCTestCase {
    /// Every bundled face, renamed both longer and shorter, must stay a valid
    /// container whose other sections still parse identically.
    func testRenamingPreservesContainerAndSections() throws {
        let urls = Bundle.main.urls(forResourcesWithExtension: "wapp", subdirectory: "bundled_faces") ?? []
        try XCTSkipIf(urls.isEmpty, "no bundled faces to rename")
        for url in urls {
            let original = try Data(contentsOf: url)
            let file = url.lastPathComponent
            for name in ["x", "regenceFace", String(repeating: "n", count: 60)] {
                let renamed = try WappBuilder.renamingIdentifier(in: original, to: name)
                XCTAssertTrue(WappReader.isValidContainer(renamed),
                              "\(file): renamed to \(name) is not a valid container")
                XCTAssertEqual(WappReader.identifier(fromWapp: renamed), name, file)
                // The sections behind the shifted offsets must still resolve.
                XCTAssertEqual(WappReader.metadata(fromWapp: renamed)?.name,
                               WappReader.metadata(fromWapp: original)?.name,
                               "\(file): display name lost after rename to \(name)")
                XCTAssertEqual(WappReader.metadata(fromWapp: renamed)?.isWatchface,
                               WappReader.metadata(fromWapp: original)?.isWatchface, file)
                XCTAssertEqual(WappReader.description(fromWapp: renamed),
                               WappReader.description(fromWapp: original), file)
                XCTAssertEqual(WappReader.configJSON(fromWapp: renamed),
                               WappReader.configJSON(fromWapp: original), file)
                XCTAssertEqual(renamed.count - original.count,
                               name.utf8.count - (WappReader.identifier(fromWapp: original)?.utf8.count ?? 0),
                               "\(file): size delta does not match the name delta")
            }
        }
    }

    /// Renaming to the identifier a file already has is a no-op, and garbage
    /// in throws rather than producing a container the watch would choke on.
    func testNoOpAndRejections() throws {
        let url = try XCTUnwrap(Bundle.main.urls(forResourcesWithExtension: "wapp",
                                                 subdirectory: "bundled_faces")?.first,
                                "no bundled faces")
        let original = try Data(contentsOf: url)
        let identifier = try XCTUnwrap(WappReader.identifier(fromWapp: original))
        XCTAssertEqual(try WappBuilder.renamingIdentifier(in: original, to: identifier), original)

        XCTAssertThrowsError(try WappBuilder.renamingIdentifier(in: Data(), to: "face"))
        XCTAssertThrowsError(try WappBuilder.renamingIdentifier(in: original, to: ""))
        XCTAssertThrowsError(try WappBuilder.renamingIdentifier(
            in: original, to: String(repeating: "n", count: 300)))
        // A truncated container must be rejected, not patched.
        XCTAssertThrowsError(try WappBuilder.renamingIdentifier(in: original.prefix(200), to: "face"))
        // A body edit that invalidates the trailing CRC32C must be refused:
        // recomputing it would hand the watch a file it can't trust.
        var corrupted = original
        corrupted[corrupted.index(corrupted.startIndex, offsetBy: corrupted.count - 40)] ^= 0xFF
        XCTAssertThrowsError(try WappBuilder.renamingIdentifier(in: corrupted, to: "face"))
    }

    /// The first attempt at a stock Fossil face failed only because the old
    /// implementation required our own builder's header shape — exactly seven
    /// used offset slots with the last one at end-of-file. A container that
    /// parks a section pointer in one of the trailing slots must rename fine,
    /// with *that* slot shifted too.
    func testRenamingShiftsOffsetsInUnusualHeaderSlots() throws {
        let url = try XCTUnwrap(Bundle.main.urls(forResourcesWithExtension: "wapp",
                                                 subdirectory: "bundled_faces")?.first,
                                "no bundled faces")
        var stockish = try Data(contentsOf: url)
        let payloadLength = Int(stockish.u32LE(at: 8))
        // Slot 13 of the inner table (file byte 76) is one of the nine our
        // builder leaves zeroed; point it into the tail of the file.
        let parked = UInt32(payloadLength)
        let slot = 76
        stockish.replaceSubrange(slot..<(slot + 4), with: [
            UInt8(parked & 0xFF), UInt8((parked >> 8) & 0xFF),
            UInt8((parked >> 16) & 0xFF), UInt8((parked >> 24) & 0xFF),
        ])
        // Re-seal it so the input is a genuinely valid container.
        let resealed = Checksums.crc32c(stockish.slice(12, payloadLength))
        stockish.replaceSubrange((12 + payloadLength)..<(12 + payloadLength + 4), with: [
            UInt8(resealed & 0xFF), UInt8((resealed >> 8) & 0xFF),
            UInt8((resealed >> 16) & 0xFF), UInt8((resealed >> 24) & 0xFF),
        ])

        let oldIdentifier = try XCTUnwrap(WappReader.identifier(fromWapp: stockish))
        let renamed = try WappBuilder.renamingIdentifier(in: stockish, to: "regenceFace")
        let delta = "regenceFace".utf8.count - oldIdentifier.utf8.count
        XCTAssertEqual(WappReader.identifier(fromWapp: renamed), "regenceFace")
        XCTAssertEqual(Int(renamed.u32LE(at: slot)), Int(parked) + delta,
                       "a section pointer in a trailing slot was not shifted")
        XCTAssertEqual(Int(renamed.u32LE(at: 24)), Int(stockish.u32LE(at: 24)),
                       "the code offset must not move")
    }
}
