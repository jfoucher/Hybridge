import Foundation

extension Collection {
    /// True when the elements are already in ascending order by `key`.
    /// Cheaper than sorting when the input is usually sorted already.
    func isSorted<T: Comparable>(by key: (Element) -> T) -> Bool {
        var previous: T?
        for element in self {
            let value = key(element)
            if let previous, previous > value { return false }
            previous = value
        }
        return true
    }
}

extension Data {
    // MARK: Little-endian appends

    mutating func appendUInt8(_ v: UInt8) {
        append(v)
    }

    mutating func appendUInt16LE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }

    mutating func appendInt16LE(_ v: Int16) {
        appendUInt16LE(UInt16(bitPattern: v))
    }

    mutating func appendInt32LE(_ v: Int32) {
        appendUInt32LE(UInt32(bitPattern: v))
    }

    mutating func appendNullTerminated(_ s: String) {
        append(s.data(using: .utf8) ?? Data())
        append(0)
    }

    // MARK: Little-endian reads (offset-based — NOT bounds-checked)
    //
    // These are *correctly indexed*: `offset` is relative to `startIndex`, so
    // they behave on a re-sliced Data where a bare subscript would read the
    // wrong bytes or trap. They do NOT bounds-check — reading past the end
    // traps and terminates the app. Every caller parsing data off the wire
    // MUST guard the length first (`guard value.count >= n`), or use
    // `ByteReader` below, which returns nil instead of trapping.

    func u8(at offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func u16LE(at offset: Int) -> UInt16 {
        UInt16(u8(at: offset)) | (UInt16(u8(at: offset + 1)) << 8)
    }

    func u32LE(at offset: Int) -> UInt32 {
        UInt32(u16LE(at: offset)) | (UInt32(u16LE(at: offset + 2)) << 16)
    }

    func i32LE(at offset: Int) -> Int32 {
        Int32(bitPattern: u32LE(at: offset))
    }

    /// Sub-range as a fresh Data (re-indexed from 0).
    func slice(_ offset: Int, _ length: Int) -> Data {
        Data(self[(startIndex + offset)..<(startIndex + offset + length)])
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let cleaned = hexString
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    /// Cryptographically secure random bytes. Traps on CSPRNG failure rather
    /// than returning the all-zero buffer `Data(count:)` starts with: these
    /// bytes seed the auth-handshake phone random and, through it, the AES-CTR
    /// IV of every encrypted file transfer. A silent zero nonce is far worse
    /// than a crash — and `SecRandomCopyBytes` failing is effectively "the
    /// device is broken" territory.
    static func random(count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return data
    }
}

extension String {
    /// A valid UTF-8 prefix no longer than `maxBytes`. Iterating Characters
    /// avoids cutting through a multi-byte scalar or grapheme cluster, which
    /// would put malformed text into a watch file.
    func utf8Prefix(maxBytes: Int) -> Data {
        guard maxBytes > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(min(utf8.count, maxBytes))
        for character in self {
            let bytes = Data(String(character).utf8)
            guard result.count + bytes.count <= maxBytes else { break }
            result.append(bytes)
        }
        return result
    }

    /// UTF-8 text including its NUL terminator, bounded for a protocol field
    /// whose total length is encoded in one byte.
    func nullTerminatedUTF8(maxLength: Int = Int(UInt8.max)) -> Data {
        precondition(maxLength >= 1)
        var result = utf8Prefix(maxBytes: maxLength - 1)
        result.append(0)
        return result
    }
}
