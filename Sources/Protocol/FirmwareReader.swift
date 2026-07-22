import Foundation

/// Detects and describes Hybrid HR firmware images (GB: FossilFileReader).
/// A DFU image starts with u32 1, u32 size, then two load addresses that are
/// always 0x00012000 or 0x00020000; the displayed version is at bytes 20/21.
enum FirmwareReader {
    static let loadAddresses: Set<UInt32> = [0x0001_2000, 0x0002_0000]
    /// GB caps firmware reads at 2 MB (FossilWatchAdapter.onInstallApp).
    static let maxSize = 2 * 1024 * 1024

    static func isFirmware(_ data: Data) -> Bool {
        guard data.count >= 32, data.count <= maxSize else { return false }
        return data.u32LE(at: 0) == 1
            && loadAddresses.contains(data.u32LE(at: 8))
            && loadAddresses.contains(data.u32LE(at: 12))
    }

    /// Human-readable version like "2.20" (the Java `% 0xff` on the first
    /// byte is a display bug; `& 0xff` is what's meant).
    static func version(_ data: Data) -> String? {
        guard isFirmware(data), data.count >= 22 else { return nil }
        return "\(data.u8(at: 20)).\(data.u8(at: 21))"
    }
}
