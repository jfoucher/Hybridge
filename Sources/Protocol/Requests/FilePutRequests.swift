import Foundation
import CoreBluetooth

/// Uploads a blob to a file handle. Protocol (all on 3dda0003/0004):
///   -> [03][handle u16][0 u32][len u32][len u32]
///   <- opcode 3 (ready)            -> stream seq-prefixed chunks on 3dda0004
///   <- opcode 8 (handle/status/crc32 of the streamed blob) -> [04][handle u16]
///   <- opcode 4 (status)           => done
class FilePutRawRequest: FossilRequest {
    let handle: UInt16
    let file: Data
    private var fullCRC: UInt32 = 0
    private var uploading = false

    init(handle: UInt16, file: Data) {
        self.handle = handle
        self.file = file
    }

    convenience init(handle: FossilFileHandle, file: Data) {
        self.init(handle: handle.rawValue, file: file)
    }

    override var idleTimeout: TimeInterval { 30 }

    override func startData() throws -> Data {
        var data = Data([0x03])
        data.appendUInt16LE(handle)
        data.appendUInt32LE(0)
        data.appendUInt32LE(declaredLength)
        data.appendUInt32LE(declaredLength)
        return data
    }

    /// Length announced in the open command; encrypted subclass adds 16.
    var declaredLength: UInt32 { UInt32(file.count) }

    /// Build the seq-prefixed packets to stream. Subclasses override to wrap
    /// or encrypt. Must also set `fullCRC` to the CRC32 the watch will report.
    func preparePackets(maxPayload: Int) throws -> [Data] {
        fullCRC = Checksums.crc32(file)
        return Self.chunk(file, maxPayload: maxPayload)
    }

    static func chunk(_ blob: Data, maxPayload: Int) -> [Data] {
        var packets: [Data] = []
        var index = 0
        var offset = 0
        while offset < blob.count {
            let length = min(maxPayload, blob.count - offset)
            var packet = Data([UInt8(index & 0xFF)])
            packet.append(blob.slice(offset, length))
            packets.append(packet)
            offset += length
            index += 1
        }
        return packets
    }

    func setFullCRC(_ crc: UInt32) { fullCRC = crc }

    override func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
        guard uuid == FossilUUID.char0003, !value.isEmpty else { return }
        switch value.u8(at: 0) & 0x0F {
        case 3:
            guard value.count == 5 else {
                throw FossilError.unexpectedResponse("file put open reply length \(value.count)")
            }
            // GB streams on any 5-byte reply, but the watch reports errors
            // here too — e.g. 134 "not enough memory" when the file doesn't
            // fit. Streaming anyway just ends in a silent watchdog timeout.
            let status = value.u8(at: 3)
            guard FossilResultCode.isSuccess(status) else {
                throw FossilError.resultCode(status, context: "file upload open")
            }
            uploading = true
            let packets = try preparePackets(maxPayload: io.maxFilePacketPayload)
            io.writeFilePackets(packets)
        case 8:
            if value.count == 4 { return } // intermediate echo, ignore
            guard value.count >= 12 else {
                throw FossilError.unexpectedResponse("file put crc reply length \(value.count)")
            }
            let status = value.u8(at: 3)
            guard FossilResultCode.isSuccess(status) else {
                throw FossilError.resultCode(status, context: "file upload")
            }
            guard value.u16LE(at: 1) == handle else {
                throw FossilError.unexpectedResponse("file put crc reply for wrong handle")
            }
            guard value.u32LE(at: 8) == fullCRC else {
                throw FossilError.crcMismatch("file upload")
            }
            var close = Data([0x04])
            close.appendUInt16LE(handle)
            io.write(close, to: FossilUUID.char0003)
        case 4:
            if value.count == 9 { return } // intermediate echo, ignore
            guard value.count == 4 else {
                throw FossilError.unexpectedResponse("file close reply length \(value.count)")
            }
            guard value.u16LE(at: 1) == handle else {
                throw FossilError.unexpectedResponse("file close reply for wrong handle")
            }
            let status = value.u8(at: 3)
            guard FossilResultCode.isSuccess(status) else {
                throw FossilError.resultCode(status, context: "file close")
            }
            isFinished = true
        case 9:
            throw FossilError.timeout("file upload (watch reported timeout)")
        default:
            break
        }
    }
}

/// DFU firmware flash: the image is streamed verbatim (no container, no
/// encryption) to the OTA handle 0x00FF (GB: FirmwareFilePutRequest). After a
/// clean close the watch applies the update by itself and reboots, dropping
/// the connection.
final class FirmwareFilePutRequest: FilePutRawRequest {
    init(firmware: Data) {
        super.init(handle: 0x00FF, file: firmware)
    }

    /// The CRC check after ~1.5 MB and the pre-reboot close can take the
    /// watch a while; don't give up during those silent stretches.
    override var idleTimeout: TimeInterval { 90 }
}

/// Adds the 16-byte file container (12-byte header + trailing CRC32C) around
/// the payload, as used by alarms, notifications and other "cooked" files.
final class FilePutRequest: FilePutRawRequest {
    init(handle: FossilFileHandle, file: Data, fileVersion: UInt16) {
        var payload = Data()
        payload.appendUInt16LE(handle.rawValue)
        payload.appendUInt16LE(fileVersion)
        payload.appendUInt32LE(0)
        payload.appendUInt32LE(UInt32(file.count))
        payload.append(file)
        payload.appendUInt32LE(Checksums.crc32c(file))
        super.init(handle: handle.rawValue, file: payload)
    }
}

/// Encrypted upload (AES-128-CTR) — used for the configuration file (0x0800).
/// The inner blob is [handle u16][02][00][0 u32][len u32][file][crc32c u32];
/// every packet (including its sequence byte) is encrypted starting from the
/// same base IV.
final class FileEncryptedPutRequest: FilePutRawRequest {
    private let key: Data
    private let phoneRandom: Data
    private let watchRandom: Data

    init(handle: UInt16, file: Data, key: Data, phoneRandom: Data, watchRandom: Data) {
        self.key = key
        self.phoneRandom = phoneRandom
        self.watchRandom = watchRandom
        super.init(handle: handle, file: file)
    }

    override var declaredLength: UInt32 { UInt32(file.count + 16) }

    override func preparePackets(maxPayload: Int) throws -> [Data] {
        var blob = Data()
        blob.appendUInt16LE(handle)
        blob.append(0x02)
        blob.append(0x00)
        blob.appendUInt32LE(0)
        blob.appendUInt32LE(UInt32(file.count))
        blob.append(file)
        blob.appendUInt32LE(Checksums.crc32c(file))

        setFullCRC(Checksums.crc32(blob))

        let iv = AESCipher.fileTransferIV(phoneRandom: phoneRandom, watchRandom: watchRandom)
        return try Self.chunk(blob, maxPayload: maxPayload).map { packet in
            try AESCipher.ctr(key: key, iv: iv, data: packet)
        }
    }
}
