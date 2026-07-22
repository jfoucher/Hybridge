import Foundation
import CoreBluetooth

/// Strict receiver for the Fossil file transport. The first byte of every
/// data packet is a six-bit sequence number (bit 6 unused/reserved) that
/// wraps at 64, not 128 — confirmed on real Hybrid HR hardware: a >64-packet
/// download (e.g. a watchface `.wapp` preview fetch) legitimately sends
/// sequence 0 again for its 65th packet. Bit 7 marks the sole terminal
/// packet. A transport CRC is only meaningful after the declared number of
/// bytes and that terminal packet have both been observed.
struct FileDownloadAccumulator {
    enum State: Equatable {
        case waitingForOpen
        case receivingPackets
        case terminalPacketSeen
        case complete
    }

    private(set) var state: State = .waitingForOpen
    private(set) var declaredSize = 0
    private(set) var buffer = Data()
    private var expectedSequence: UInt8 = 0

    mutating func open(size: Int, context: String) throws {
        guard state == .waitingForOpen else {
            throw FossilError.unexpectedResponse("duplicate \(context) open response")
        }
        guard size >= 0, size <= fossilMaxFileSize else {
            throw FossilError.unexpectedResponse(
                "declared \(context) size \(size) exceeds \(fossilMaxFileSize)")
        }
        declaredSize = size
        buffer = Data()
        buffer.reserveCapacity(size)
        expectedSequence = 0
        state = .receivingPackets
    }

    mutating func append(packet: Data, context: String) throws {
        guard state == .receivingPackets else {
            throw FossilError.unexpectedResponse(
                state == .waitingForOpen
                    ? "\(context) data arrived before open response"
                    : "\(context) data arrived after terminal packet")
        }
        guard !packet.isEmpty else {
            throw FossilError.unexpectedResponse("empty \(context) data packet")
        }
        let flag = packet.u8(at: 0)
        let sequence = flag & 0x3F
        guard sequence == expectedSequence else {
            throw FossilError.unexpectedResponse(
                "\(context) packet sequence \(sequence), expected \(expectedSequence)")
        }
        let payloadCount = packet.count - 1
        guard buffer.count + payloadCount <= declaredSize else {
            throw FossilError.unexpectedResponse(
                "\(context) data exceeds declared size \(declaredSize)")
        }
        if payloadCount > 0 { buffer.append(packet.dropFirst()) }
        expectedSequence = (expectedSequence &+ 1) & 0x3F

        if flag & 0x80 != 0 {
            guard buffer.count == declaredSize else {
                throw FossilError.unexpectedResponse(
                    "\(context) terminal packet at \(buffer.count) of \(declaredSize) bytes")
            }
            state = .terminalPacketSeen
        } else if buffer.count == declaredSize {
            throw FossilError.unexpectedResponse(
                "\(context) reached declared size without terminal packet")
        }
    }

    mutating func finish(expectedCRC: UInt32, context: String) throws -> Data {
        guard state == .terminalPacketSeen else {
            throw FossilError.unexpectedResponse(
                "\(context) CRC arrived before a complete terminal packet")
        }
        guard buffer.count == declaredSize else {
            throw FossilError.unexpectedResponse(
                "\(context) received \(buffer.count) of \(declaredSize) bytes")
        }
        guard Checksums.crc32(buffer) == expectedCRC else {
            throw FossilError.crcMismatch(context)
        }
        state = .complete
        return buffer
    }
}

/// Validates the cooked 12-byte Fossil header and trailing CRC32C before any
/// payload reaches a parser.
enum FossilFileContainer {
    static func payload(from data: Data, expectedHandle: UInt16) throws -> Data {
        guard data.count >= 16 else {
            throw FossilError.unexpectedResponse("file container is shorter than 16 bytes")
        }
        guard data.u16LE(at: 0) == expectedHandle else {
            throw FossilError.unexpectedResponse("file container has the wrong handle")
        }
        let payloadLength = Int(data.u32LE(at: 8))
        guard payloadLength <= fossilMaxFileSize,
              payloadLength <= Int.max - 16,
              data.count == payloadLength + 16 else {
            throw FossilError.unexpectedResponse(
                "file container length does not match its declaration")
        }
        let payload = data.slice(12, payloadLength)
        guard Checksums.crc32c(payload) == data.u32LE(at: 12 + payloadLength) else {
            throw FossilError.crcMismatch("file container")
        }
        return payload
    }

    static func validate(_ data: Data, expectedHandle: UInt16) throws {
        _ = try payload(from: data, expectedHandle: expectedHandle)
    }
}

/// Downloads a raw file:
///   -> [01][minor][major][0 u32][FFFFFFFF u32]
///   <- opcode 1 (status + size), data chunks on 3dda0004 (bit7 of byte0 = last)
///   <- opcode 8 (crc32) => done
final class FileGetRawRequest: FossilRequest {
    let major: UInt8
    let minor: UInt8
    private var receiver = FileDownloadAccumulator()
    private(set) var fileData: Data?

    init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }

    convenience init(handle: UInt16) {
        self.init(major: UInt8((handle >> 8) & 0xFF), minor: UInt8(handle & 0xFF))
    }

    convenience init(handle: FossilFileHandle) {
        self.init(major: handle.major, minor: handle.minor)
    }

    override var idleTimeout: TimeInterval { 20 }

    /// Validated file content with the 12-byte header and trailing CRC removed.
    /// `expectedHandle` defaults to the handle this file was fetched from, but
    /// some formats (notably `.wapp`, whose header always carries the fixed
    /// `FossilFileHandle.appCode` regardless of which storage slot it lives
    /// in) bake in a different constant — pass it explicitly for those.
    func strippedFileData(expectedHandle: UInt16? = nil) throws -> Data {
        guard let fileData else {
            throw FossilError.unexpectedResponse("file download did not complete")
        }
        return try FossilFileContainer.payload(
            from: fileData, expectedHandle: expectedHandle ?? (UInt16(major) << 8 | UInt16(minor)))
    }

    /// Verifies the inner container while retaining its header for parsers
    /// whose format offsets are relative to that header (notably activity and
    /// `.wapp`). See `strippedFileData` re: `expectedHandle`.
    func validatedFileData(expectedHandle: UInt16? = nil) throws -> Data {
        guard let fileData else {
            throw FossilError.unexpectedResponse("file download did not complete")
        }
        try FossilFileContainer.validate(
            fileData, expectedHandle: expectedHandle ?? (UInt16(major) << 8 | UInt16(minor)))
        return fileData
    }

    override func startData() throws -> Data {
        var data = Data([0x01, minor, major])
        data.appendUInt32LE(0)
        data.appendUInt32LE(0xFFFF_FFFF)
        return data
    }

    override func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
        if uuid == FossilUUID.char0003 {
            guard !value.isEmpty else { return }
            // Ignore stale frames addressed to another handle — late async
            // replies or opcode-9 session timeouts from a previous transfer.
            // Applying them here would abort this download. Data packets carry
            // no handle and are handled on char0004 below.
            if value.count >= 3, value.u16LE(at: 1) != UInt16(major) << 8 | UInt16(minor) { return }
            switch value.u8(at: 0) & 0x0F {
            case 1:
                guard value.count >= 8 else {
                    throw FossilError.unexpectedResponse("short file get open response")
                }
                guard value.u8(at: 1) == minor, value.u8(at: 2) == major else {
                    throw FossilError.unexpectedResponse("file get open response for wrong handle")
                }
                let status = value.u8(at: 3)
                guard FossilResultCode.isSuccess(status) else {
                    throw FossilError.resultCode(status, context: "file get")
                }
                try receiver.open(size: Int(value.u32LE(at: 4)), context: "file download")
            case 8:
                guard value.count >= 12 else {
                    throw FossilError.unexpectedResponse("short file get CRC response")
                }
                guard value.u8(at: 1) == minor, value.u8(at: 2) == major else {
                    throw FossilError.unexpectedResponse("file get CRC response for wrong handle")
                }
                fileData = try receiver.finish(expectedCRC: value.u32LE(at: 8),
                                               context: "file download")
                isFinished = true
            case 9:
                throw FossilError.timeout("file download (watch reported timeout)")
            default:
                break
            }
        } else if uuid == FossilUUID.char0004 {
            try receiver.append(packet: value, context: "file download")
        }
    }
}

/// Resolves the concrete file handle for a major handle (needed before
/// downloading e.g. the installed-apps file):
///   -> [02][FF][major]
///   <- opcode 2 (status + size), content chunks on 3dda0004, opcode 8 (crc)
/// The downloaded content starts with the concrete handle as a LE u16.
final class FileLookupRequest: FossilRequest {
    let major: UInt8
    private var receiver = FileDownloadAccumulator()
    private(set) var resolvedHandle: UInt16?
    private(set) var fileEmpty = false

    init(major: UInt8) {
        self.major = major
    }

    override func startData() throws -> Data {
        Data([0x02, 0xFF, major])
    }

    override func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
        if uuid == FossilUUID.char0003 {
            guard !value.isEmpty else { return }
            switch value.u8(at: 0) & 0x0F {
            case 2:
                guard value.count >= 8 else {
                    throw FossilError.unexpectedResponse("short file lookup open response")
                }
                let status = value.u8(at: 3)
                guard FossilResultCode.isSuccess(status) else {
                    throw FossilError.resultCode(status, context: "file lookup")
                }
                let size = Int(value.u32LE(at: 4))
                if size == 0 {
                    fileEmpty = true
                    isFinished = true
                } else {
                    try receiver.open(size: size, context: "file lookup")
                }
            case 8:
                guard value.count >= 12 else {
                    throw FossilError.unexpectedResponse("short file lookup CRC response")
                }
                let buffer = try receiver.finish(expectedCRC: value.u32LE(at: 8),
                                                 context: "file lookup")
                guard buffer.count >= 2 else {
                    throw FossilError.unexpectedResponse("empty lookup result")
                }
                resolvedHandle = buffer.u16LE(at: 0)
                isFinished = true
            default:
                break
            }
        } else if uuid == FossilUUID.char0004 {
            try receiver.append(packet: value, context: "file lookup")
        }
    }
}

/// Deletes a file: -> [0B][handle u16], <- 0x8B + handle + status.
final class FileDeleteRequest: FossilRequest {
    let handle: UInt16

    init(handle: UInt16) {
        self.handle = handle
    }

    override func startData() throws -> Data {
        var data = Data([0x0B])
        data.appendUInt16LE(handle)
        return data
    }

    override func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
        guard uuid == FossilUUID.char0003, value.count == 4, value.u8(at: 0) == 0x8B else { return }
        guard value.u16LE(at: 1) == handle else {
            throw FossilError.unexpectedResponse("file delete reply for wrong handle")
        }
        let status = value.u8(at: 3)
        guard FossilResultCode.isSuccess(status) else {
            throw FossilError.resultCode(status, context: "file delete")
        }
        isFinished = true
    }
}
