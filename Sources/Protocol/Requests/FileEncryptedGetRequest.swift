import Foundation
import CoreBluetooth

/// Downloads and decrypts a file (AES-128-CTR) — used for the activity file.
/// Each incoming BLE packet is decrypted independently with the base IV
/// advanced by `ivIncrementor × N` (N = 0-based packet index); the incrementor
/// is brute-forced on the second packet by checking the decrypted flag byte
/// (0x01, or 0x81 for the last). 
final class FileEncryptedGetRequest: FossilRequest {
    let major: UInt8
    let minor: UInt8
    private let key: Data
    private let baseIV: Data

    private var fileSize = 0
    private var receiver = FileDownloadAccumulator()
    private var packetCount = 0
    private var ivIncrementor = 0x1F
    private(set) var fileData: Data?

    func validatedFileData() throws -> Data {
        guard let fileData else {
            throw FossilError.unexpectedResponse("encrypted file download did not complete")
        }
        try FossilFileContainer.validate(
            fileData, expectedHandle: UInt16(major) << 8 | UInt16(minor))
        return fileData
    }

    /// Validated file content with the cooked 12-byte header and trailing
    /// CRC removed, for parsers whose offsets are payload-relative.
    func strippedFileData() throws -> Data {
        guard let fileData else {
            throw FossilError.unexpectedResponse("encrypted file download did not complete")
        }
        return try FossilFileContainer.payload(
            from: fileData, expectedHandle: UInt16(major) << 8 | UInt16(minor))
    }

    init(handle: UInt16, key: Data, phoneRandom: Data, watchRandom: Data) {
        self.major = UInt8((handle >> 8) & 0xFF)
        self.minor = UInt8(handle & 0xFF)
        self.key = key
        self.baseIV = AESCipher.fileTransferIV(phoneRandom: phoneRandom, watchRandom: watchRandom)
    }

    override var idleTimeout: TimeInterval { 30 }

    override func startData() throws -> Data {
        var data = Data([0x01, minor, major])
        data.appendUInt32LE(0)
        data.appendUInt32LE(0xFFFF_FFFF)
        return data
    }

    private func incrementedIV(by amount: Int) -> Data {
        var iv = baseIV
        // 32-bit big-endian counter in iv[12..15]
        var counter: UInt32 = 0
        for i in 12..<16 { counter = (counter << 8) | UInt32(iv[i]) }
        counter = counter &+ UInt32(truncatingIfNeeded: amount)
        for i in 0..<4 { iv[15 - i] = UInt8((counter >> (8 * UInt32(i))) & 0xFF) }
        return iv
    }

    override func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
        if uuid == FossilUUID.char0003 {
            guard !value.isEmpty else { return }
            // Ignore stale frames addressed to another handle — late async
            // replies or opcode-9 session timeouts from a previous transfer.
            // Applying them here would abort this download. Encrypted data
            // packets carry no handle and are handled on char0004 below.
            if value.count >= 3, value.u16LE(at: 1) != UInt16(major) << 8 | UInt16(minor) { return }
            switch value.u8(at: 0) & 0x0F {
            case 1:
                guard value.count >= 8 else {
                    throw FossilError.unexpectedResponse("short encrypted file get open response")
                }
                guard value.u8(at: 1) == minor, value.u8(at: 2) == major else {
                    throw FossilError.unexpectedResponse("encrypted file get response for wrong handle")
                }
                let status = value.u8(at: 3)
                guard FossilResultCode.isSuccess(status) else {
                    throw FossilError.resultCode(status, context: "encrypted file get")
                }
                fileSize = Int(value.u32LE(at: 4))
                try receiver.open(size: fileSize, context: "encrypted file download")
                packetCount = 0
            case 8:
                guard value.count >= 12 else {
                    throw FossilError.unexpectedResponse("short encrypted file get CRC response")
                }
                guard value.u8(at: 1) == minor, value.u8(at: 2) == major else {
                    throw FossilError.unexpectedResponse("encrypted file get CRC response for wrong handle")
                }
                fileData = try receiver.finish(expectedCRC: value.u32LE(at: 8),
                                               context: "encrypted file download")
                isFinished = true
            case 9:
                throw FossilError.timeout("encrypted download (watch reported timeout)")
            default:
                break
            }
        } else if uuid == FossilUUID.char0004 {
            guard receiver.state == .receivingPackets else {
                // Let the shared state machine produce the canonical ordering error.
                try receiver.append(packet: value, context: "encrypted file download")
                return
            }
            guard !value.isEmpty else {
                throw FossilError.unexpectedResponse("empty encrypted file data packet")
            }
            var result: Data
            if packetCount == 1 {
                // Find how many CTR blocks the watch advanced per packet.
                var found: Data?
                for summand in 0x1E..<0x30 {
                    let candidate = try AESCipher.ctr(key: key,
                                                      iv: incrementedIV(by: summand),
                                                      data: value)
                    let currentLength = receiver.buffer.count + candidate.count - 1
                    let expected: UInt8 = currentLength == fileSize ? 0x81 : 0x01
                    if candidate.u8(at: 0) == expected {
                        ivIncrementor = summand
                        found = candidate
                        break
                    }
                }
                guard let found else {
                    throw FossilError.unexpectedResponse("no CTR counter offset matched (0x1E–0x2F)")
                }
                result = found
            } else {
                result = try AESCipher.ctr(key: key,
                                           iv: incrementedIV(by: ivIncrementor * packetCount),
                                           data: value)
            }
            packetCount += 1
            try receiver.append(packet: result, context: "encrypted file download")
        }
    }
}
