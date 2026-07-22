import Foundation
import Security

/// Stores each watch's 16-byte authentication key in the iOS Keychain, one
/// entry per watch (account = peripheral UUID). Pre-multi-watch builds used
/// a single fixed account; AppMigrations moves that entry to the first
/// registered watch.
enum KeychainStore {
    private static let service = "eu.sixpixels.hybridge.authkey"
    private static let legacyAccount = "watch"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Stores `key` for one watch. Returns false if the keychain rejected it —
    /// callers must surface that rather than assume success: key entry is the
    /// hardest step in onboarding, and a silent failure here shows up much
    /// later as an unexplained authentication failure on the next connect.
    @discardableResult
    static func saveKey(_ key: Data, for watchID: UUID) -> Bool {
        save(key, account: watchID.uuidString)
    }

    static func loadKey(for watchID: UUID) -> Data? {
        load(account: watchID.uuidString)
    }

    static func deleteKey(for watchID: UUID) {
        SecItemDelete(baseQuery(account: watchID.uuidString) as CFDictionary)
    }

    // The pre-multi-watch single entry, read only for migration/adoption.

    static func loadLegacyKey() -> Data? {
        load(account: legacyAccount)
    }

    static func deleteLegacyKey() {
        SecItemDelete(baseQuery(account: legacyAccount) as CFDictionary)
    }

    @discardableResult
    private static func save(_ key: Data, account: String) -> Bool {
        // Replace in place so a transient keychain failure cannot destroy the
        // valid key that was already stored. Only fall back to an add when no
        // item exists yet.
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: key] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            NSLog("KeychainStore: SecItemUpdate failed with OSStatus \(updateStatus)")
            return false
        }
        var query = baseQuery(account: account)
        query[kSecValueData as String] = key
        // Deliberately NOT `…ThisDeviceOnly`: the key then survives an
        // encrypted device backup, so migrating to a new phone doesn't force
        // the user to re-extract and re-type 32 hex characters per watch
        // (see WatchRegistry.register, which adopts a restored legacy key).
        // The accepted exposure is narrow — an attacker needs the encrypted
        // backup *and* physical proximity to that specific watch.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("KeychainStore: SecItemAdd failed with OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    private static func load(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count == 16 else { return nil }
        return data
    }
}
