import Foundation
import CoreBluetooth

/// Downloads a raw file:
///   -> [01][minor][major][0 u32][FFFFFFFF u32]
///   <- opcode 1 (status + size), data chunks on 3dda0004 (bit7 of byte0 = last)
///   <- opcode 8 (crc32) => done
final class FileGetRawRequest: FossilRequest {
    let major: UInt8
    let minor: UInt8
    private var buffer = Data()
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

    /// File content with the 12-byte header and 4-byte trailing CRC removed.
    var strippedFileData: Data? {
        guard let fileData, fileData.count > 16 else { return nil }
        return fileData.slice(12, fileData.count - 16)
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
            switch value.u8(at: 0) & 0x0F {
            case 1:
                guard value.count >= 8 else { return }
                let status = value.u8(at: 3)
                guard FossilResultCode.isSuccess(status) else {
                    throw FossilError.resultCode(status, context: "file get")
                }
                let declared = Int(value.u32LE(at: 4))
                guard declared <= fossilMaxFileSize else {
                    throw FossilError.unexpectedResponse("declared file size \(declared) exceeds \(fossilMaxFileSize)")
                }
                buffer = Data()
                buffer.reserveCapacity(declared)
            case 8:
                guard value.count >= 12 else { return }
                guard Checksums.crc32(buffer) == value.u32LE(at: 8) else {
                    throw FossilError.crcMismatch("file download")
                }
                fileData = buffer
                isFinished = true
            case 9:
                throw FossilError.timeout("file download (watch reported timeout)")
            default:
                break
            }
        } else if uuid == FossilUUID.char0004 {
            guard !value.isEmpty else { return }
            // A peer that never sends the terminating opcode-8 frame would
            // otherwise grow this buffer until the app is killed.
            guard buffer.count + value.count <= fossilMaxFileSize else {
                throw FossilError.unexpectedResponse("file download exceeded \(fossilMaxFileSize) bytes")
            }
            buffer.append(value.slice(1, value.count - 1))
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
    private var buffer = Data()
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
                guard value.count >= 8 else { return }
                let status = value.u8(at: 3)
                guard FossilResultCode.isSuccess(status) else {
                    throw FossilError.resultCode(status, context: "file lookup")
                }
                if value.u32LE(at: 4) == 0 {
                    fileEmpty = true
                    isFinished = true
                }
            case 8:
                guard value.count >= 12 else { return }
                guard Checksums.crc32(buffer) == value.u32LE(at: 8) else {
                    throw FossilError.crcMismatch("file lookup")
                }
                guard buffer.count >= 2 else {
                    throw FossilError.unexpectedResponse("empty lookup result")
                }
                resolvedHandle = buffer.u16LE(at: 0)
                isFinished = true
            default:
                break
            }
        } else if uuid == FossilUUID.char0004 {
            guard !value.isEmpty else { return }
            guard buffer.count + value.count <= fossilMaxFileSize else {
                throw FossilError.unexpectedResponse("file lookup exceeded \(fossilMaxFileSize) bytes")
            }
            buffer.append(value.slice(1, value.count - 1))
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
