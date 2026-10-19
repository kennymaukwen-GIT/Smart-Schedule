import Foundation
import Security

/// Whether the iPhone is locked right now, for the notification extension (no UIApplication there). A 1-byte keychain
/// item readable only while unlocked: reading or adding it while locked fails with errSecInteractionNotAllowed. Any other
/// result counts as unlocked (fail open), so a keychain problem never disables replies. Holds no personal data.
/// Reports unlocked for about 10 s after locking (class-key grace period).
enum DeviceLock {
    private static let service = "com.smartschedule.lockprobe"

    static func isLocked() -> Bool {
        var query = baseQuery
        query[kSecReturnData as String] = true            // the secret, not just attributes: only it is class-protected
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let read = SecItemCopyMatching(query as CFDictionary, &item)
        guard read == errSecItemNotFound else { return meansLocked(read) }
        var add = baseQuery
        add[kSecValueData as String] = Data([1])
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return meansLocked(SecItemAdd(add as CFDictionary, nil))
    }

    /// Pure: the keychain's answer for an item that is readable only while unlocked.
    static func meansLocked(_ status: OSStatus) -> Bool { status == errSecInteractionNotAllowed }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "probe"]
    }
}
