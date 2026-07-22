import Foundation

/// CRC32 (zlib polynomial, reflected) and CRC32C (Castagnoli) — both used by the
/// Fossil file transport: CRC32 verifies the transferred blob, CRC32C is embedded
/// in the file container header.
enum Checksums {
    private static let crc32Table: [UInt32] = makeTable(polynomial: 0xEDB8_8320)
    private static let crc32cTable: [UInt32] = makeTable(polynomial: 0x82F6_3B78)

    private static func makeTable(polynomial: UInt32) -> [UInt32] {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (polynomial ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }

    private static func crc(_ data: Data, table: [UInt32]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    static func crc32(_ data: Data) -> UInt32 {
        crc(data, table: crc32Table)
    }

    static func crc32c(_ data: Data) -> UInt32 {
        crc(data, table: crc32cTable)
    }
}
