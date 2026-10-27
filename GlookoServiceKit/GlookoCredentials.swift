import Foundation
import Security

/// App-scoped credentials remain available in the background after first unlock, but do not migrate
/// to another device or synchronise through iCloud. New sign-ins retain a password only when enabled;
/// existing installations preserve their recovery setting until the user changes it.
struct GlookoCredentials {
    private func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrSynchronizable as String: false]
    }
    func get(_ service: String) throws -> String? {
        var q = query(service); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return value
    }
    func set(_ value: String?, service: String) throws {
        guard let value else { try remove(service); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(service) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(service); attributes.forEach { q[$0.key] = $0.value }
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    func remove(_ service: String) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
