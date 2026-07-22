import Foundation
import CoreBluetooth

/// AES-128-CBC challenge/response handshake on 3dda0005 using the user's
/// 16-byte watch key. On success the exchanged 8-byte random numbers are kept:
/// they seed the AES-CTR IV of every encrypted file transfer that follows.
final class VerifyPrivateKeyRequest: FossilRequest {
    private let key: Data
    private let phoneRandom: Data

    /// Set on success.
    private(set) var watchRandom: Data?
    var resultRandoms: (phone: Data, watch: Data)? {
        guard let watchRandom else { return nil }
        return (phoneRandom, watchRandom)
    }

    init(key: Data) {
        self.key = key
        self.phoneRandom = Data.random(count: 8)
    }

    override var startUUID: CBUUID { FossilUUID.char0005 }

    override func startData() throws -> Data {
        var data = Data([0x02, 0x01, 0x01])
        data.append(phoneRandom)
        return data
    }

    override func handle(uuid: CBUUID, value: Data, io: RequestIO) throws {
        guard uuid == FossilUUID.char0005, value.count >= 3 else { return }
        switch value.u8(at: 1) {
        case 1:
            guard value.count >= 20 else {
                throw FossilError.unexpectedResponse("short auth challenge (\(value.count) bytes)")
            }
            let decrypted = try AESCipher.cbcDecrypt(key: key, data: value.slice(4, 16))
            // decrypted = [watchRandom(8) | phoneRandom echo(8)]; reply with halves swapped
            let watch = decrypted.slice(0, 8)
            let phoneEcho = decrypted.slice(8, 8)
            guard phoneEcho == phoneRandom else {
                throw FossilError.authenticationFailed("phone random mismatch — wrong key?")
            }
            watchRandom = watch
            var toEncrypt = Data()
            toEncrypt.append(phoneEcho)
            toEncrypt.append(watch)
            let encrypted = try AESCipher.cbcEncrypt(key: key, data: toEncrypt)
            var reply = Data([0x02, 0x02, 0x01])
            reply.append(encrypted)
            io.write(reply, to: FossilUUID.char0005)
        case 2:
            let code = value.u8(at: 2)
            guard FossilResultCode.isSuccess(code) else {
                throw FossilError.authenticationFailed(FossilResultCode.describe(code))
            }
            isFinished = true
        default:
            break
        }
    }
}
