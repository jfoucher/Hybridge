import XCTest
import CoreBluetooth
@testable import Hybridge

/// The file-download paths accept a size declared by the peer. The peer is not
/// trustworthy: discovery matches on advertised name/service UUID, which any
/// nearby device can claim, and the Q family runs this protocol with no crypto
/// at all. An unclamped declaration pre-allocates the buffer and gets the app
/// jetsammed, so both the declared size and the accumulated chunks are capped.
final class FileTransferLimitTests: XCTestCase {

    private final class NullIO: RequestIO {
        var maxFilePacketPayload: Int { 19 }
        func write(_ data: Data, to uuid: CBUUID) {}
        func writeFilePackets(_ packets: [Data]) {}
    }

    /// A file-get status frame (opcode 1) declaring `size` bytes.
    private func statusFrame(opcode: UInt8, size: UInt32) -> Data {
        var data = Data([opcode, 0x00, 0x01, 0x00])   // [opcode][minor][major][status=success]
        data.appendUInt32LE(size)
        return data
    }

    private func dataChunk(_ byteCount: Int) -> Data {
        Data([0x00]) + Data(repeating: 0xAB, count: byteCount)
    }

    // MARK: - Declared size

    func testRawGetRejectsOversizedDeclaration() {
        let request = FileGetRawRequest(handle: 0x0100)
        XCTAssertThrowsError(
            try request.handle(uuid: FossilUUID.char0003,
                               value: statusFrame(opcode: 1, size: 0xFFFF_FFFF),
                               io: NullIO()),
            "a 4 GiB declaration must be refused, not reserved")
    }

    func testEncryptedGetRejectsOversizedDeclaration() {
        let request = FileEncryptedGetRequest(handle: 0x0100,
                                              key: Data(repeating: 0, count: 16),
                                              phoneRandom: Data(repeating: 1, count: 8),
                                              watchRandom: Data(repeating: 2, count: 8))
        XCTAssertThrowsError(
            try request.handle(uuid: FossilUUID.char0003,
                               value: statusFrame(opcode: 1, size: 0xFFFF_FFFF),
                               io: NullIO()))
    }

    func testRealisticDeclarationIsAccepted() throws {
        // The largest genuine file is the OTA image — a few hundred KB.
        let request = FileGetRawRequest(handle: 0x0100)
        XCTAssertNoThrow(
            try request.handle(uuid: FossilUUID.char0003,
                               value: statusFrame(opcode: 1, size: 300_000),
                               io: NullIO()))
        XCTAssertFalse(request.isFinished)
    }

    func testSizeAtTheLimitIsAccepted() {
        let request = FileGetRawRequest(handle: 0x0100)
        XCTAssertNoThrow(
            try request.handle(uuid: FossilUUID.char0003,
                               value: statusFrame(opcode: 1, size: UInt32(fossilMaxFileSize)),
                               io: NullIO()))
    }

    // MARK: - Accumulated chunks

    func testRawGetStopsAccumulatingPastTheLimit() {
        // A peer that declares a small file and then never stops sending, or
        // never sends the terminating opcode-8 frame, must not grow the
        // buffer without bound.
        let request = FileGetRawRequest(handle: 0x0100)
        let io = NullIO()
        try? request.handle(uuid: FossilUUID.char0003,
                            value: statusFrame(opcode: 1, size: 1024), io: io)

        let chunk = dataChunk(4096)
        var threw = false
        for _ in 0..<(fossilMaxFileSize / 4096 + 10) {
            do {
                try request.handle(uuid: FossilUUID.char0004, value: chunk, io: io)
            } catch {
                threw = true
                break
            }
        }
        XCTAssertTrue(threw, "chunk accumulation is unbounded")
    }

    func testLookupStopsAccumulatingPastTheLimit() {
        let request = FileLookupRequest(major: 0x01)
        let io = NullIO()
        let chunk = dataChunk(4096)
        var threw = false
        for _ in 0..<(fossilMaxFileSize / 4096 + 10) {
            do {
                try request.handle(uuid: FossilUUID.char0004, value: chunk, io: io)
            } catch {
                threw = true
                break
            }
        }
        XCTAssertTrue(threw, "lookup chunk accumulation is unbounded")
    }

    func testNormalSizedDownloadStillCompletes() throws {
        let request = FileGetRawRequest(handle: 0x0100)
        let io = NullIO()
        let payload = Data(repeating: 0x5A, count: 512)

        try request.handle(uuid: FossilUUID.char0003,
                           value: statusFrame(opcode: 1, size: UInt32(payload.count)), io: io)
        try request.handle(uuid: FossilUUID.char0004, value: Data([0x80]) + payload, io: io)

        var done = Data([0x08, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])
        done.appendUInt32LE(Checksums.crc32(payload))
        try request.handle(uuid: FossilUUID.char0003, value: done, io: io)

        XCTAssertTrue(request.isFinished)
        XCTAssertEqual(request.fileData, payload)
    }

    func testDataBeforeOpenIsRejected() {
        var receiver = FileDownloadAccumulator()
        XCTAssertThrowsError(try receiver.append(packet: Data([0x80, 1]), context: "test"))
    }

    func testDeclaredSizeWithoutTerminalFlagIsRejected() throws {
        var receiver = FileDownloadAccumulator()
        try receiver.open(size: 2, context: "test")
        XCTAssertThrowsError(try receiver.append(packet: Data([0x00, 1, 2]), context: "test"))
    }

    func testPartialTerminalPacketIsRejectedEvenWithMatchingPartialCRC() throws {
        var receiver = FileDownloadAccumulator()
        try receiver.open(size: 3, context: "test")
        XCTAssertThrowsError(try receiver.append(packet: Data([0x80, 1, 2]), context: "test"))
    }

    func testDuplicateAndOutOfOrderSequencesAreRejected() throws {
        var duplicate = FileDownloadAccumulator()
        try duplicate.open(size: 2, context: "test")
        try duplicate.append(packet: Data([0x00, 1]), context: "test")
        XCTAssertThrowsError(try duplicate.append(packet: Data([0x80, 2]), context: "test"))

        var skipped = FileDownloadAccumulator()
        try skipped.open(size: 1, context: "test")
        XCTAssertThrowsError(try skipped.append(packet: Data([0x81, 1]), context: "test"))
    }

    func testCRCBeforeTerminalAndFramesAfterCompletionAreRejected() throws {
        var receiver = FileDownloadAccumulator()
        try receiver.open(size: 1, context: "test")
        XCTAssertThrowsError(try receiver.finish(expectedCRC: 0, context: "test"))
        try receiver.append(packet: Data([0x80, 7]), context: "test")
        _ = try receiver.finish(expectedCRC: Checksums.crc32(Data([7])), context: "test")
        XCTAssertThrowsError(try receiver.append(packet: Data([0x81, 8]), context: "test"))
    }

    func testInnerContainerRejectsWrongLengthTrailingBytesAndCRC() throws {
        let payload = Data([1, 2, 3])
        var valid = Data()
        valid.appendUInt16LE(0x0100)
        valid.append(contentsOf: [2, 0])
        valid.appendUInt32LE(0)
        valid.appendUInt32LE(UInt32(payload.count))
        valid.append(payload)
        valid.appendUInt32LE(Checksums.crc32c(payload))
        XCTAssertEqual(try FossilFileContainer.payload(from: valid, expectedHandle: 0x0100), payload)

        var trailing = valid; trailing.append(0)
        XCTAssertThrowsError(try FossilFileContainer.validate(trailing, expectedHandle: 0x0100))
        var corrupt = valid; corrupt[12] ^= 0xFF
        XCTAssertThrowsError(try FossilFileContainer.validate(corrupt, expectedHandle: 0x0100))
        XCTAssertThrowsError(try FossilFileContainer.validate(valid, expectedHandle: 0x0200))
    }
}
