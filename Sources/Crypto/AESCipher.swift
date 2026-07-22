import Foundation
import CommonCrypto

enum AESError: Error {
    case cryptorFailure(Int32)
    case badKeyLength
}

/// AES primitives used by the Fossil HR protocol.
/// - Handshake: AES-128-CBC with a zero IV, no padding (16-byte blocks only).
/// - File upload: AES-128-CTR; each BLE packet is encrypted independently,
///   restarting from the same base IV (the firmware's behavior).
enum AESCipher {
    static func cbc(_ operation: CCOperation, key: Data, data: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw AESError.badKeyLength }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let zeroIV = Data(count: 16)
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    zeroIV.withUnsafeBytes { ivPtr in
                        CCCrypt(operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                0, // no padding, CBC mode
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                inPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw AESError.cryptorFailure(status) }
        return out.prefix(moved)
    }

    static func cbcEncrypt(key: Data, data: Data) throws -> Data {
        try cbc(CCOperation(kCCEncrypt), key: key, data: data)
    }

    static func cbcDecrypt(key: Data, data: Data) throws -> Data {
        try cbc(CCOperation(kCCDecrypt), key: key, data: data)
    }

    /// One-shot AES-CTR starting at the given IV (big-endian counter).
    static func ctr(key: Data, iv: Data, data: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw AESError.badKeyLength }
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt),
                                        CCMode(kCCModeCTR),
                                        CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding),
                                        ivPtr.baseAddress,
                                        keyPtr.baseAddress, key.count,
                                        nil, 0, 0,
                                        CCModeOptions(kCCModeOptionCTR_BE),
                                        &cryptor)
            }
        }
        guard createStatus == kCCSuccess, let cryptor else { throw AESError.cryptorFailure(createStatus) }
        defer { CCCryptorRelease(cryptor) }

        var out = Data(count: data.count)
        let outCapacity = out.count
        var moved = 0
        let updateStatus = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                CCCryptorUpdate(cryptor,
                                inPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity,
                                &moved)
            }
        }
        guard updateStatus == kCCSuccess else { throw AESError.cryptorFailure(updateStatus) }
        return out.prefix(moved)
    }

    /// The 16-byte IV used for encrypted file transfers, built from the random
    /// numbers exchanged during the key handshake.
    static func fileTransferIV(phoneRandom: Data, watchRandom: Data) -> Data {
        var iv = Data(count: 16)
        for i in 0..<6 { iv[2 + i] = phoneRandom[phoneRandom.startIndex + i] }
        for i in 0..<7 { iv[9 + i] = watchRandom[watchRandom.startIndex + i] }
        iv[7] &+= 1
        return iv
    }
}
