import Foundation
import Security

/// Keychain items in the shared access group so the notification content extension can refresh
/// Google tokens without the app running.
///
/// `kSecAttrAccessibleAfterFirstUnlock` is deliberate: the "hold to spawn" UI runs on the Lock Screen,
/// where `WhenUnlocked` items are unreadable.
enum KeychainStore {
    private static let service = "com.smartschedule.tokens"

    static func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        var query = baseQuery(key: key)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func delete(key: String) {
        SecItemDelete(baseQuery(key: key) as CFDictionary)
    }

    /// Every item of the service: each account's tokens and the single-account version's item (erase).
    static func deleteAll() {
        SecItemDelete(baseQuery(key: nil) as CFDictionary)
    }

    private static func baseQuery(key: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let key { query[kSecAttrAccount as String] = key }
        if let group = AppConstants.keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }
}
