import Foundation
import Security

enum KeychainStore {
    struct Item: Codable, Sendable {
        var username: String
        var secret: String
    }

    private static let service = "com.maneeshacooray.gitling.ios"

    static func save(host: String, username: String, secret: String) {
        guard let data = try? JSONEncoder().encode(Item(username: username, secret: secret)) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func load(host: String) -> Item? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Item.self, from: data)
    }

    static func delete(host: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func saveSecret(_ secret: String, accountID: UUID) {
        guard let data = secret.data(using: .utf8) else { return }
        let key = "account:\(accountID.uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func loadSecret(accountID: UUID) -> String? {
        let key = "account:\(accountID.uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteSecret(accountID: UUID) {
        let key = "account:\(accountID.uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func saveSSHKey(_ privateKey: String, id: UUID) {
        saveSecret(privateKey, key: "ssh-key:\(id.uuidString)")
    }

    static func loadSSHKey(id: UUID) -> String? {
        loadSecret(key: "ssh-key:\(id.uuidString)")
    }

    static func deleteSSHKey(id: UUID) {
        deleteSecret(key: "ssh-key:\(id.uuidString)")
        deleteSecret(key: "ssh-passphrase:\(id.uuidString)")
    }

    static func saveSSHPassphrase(_ passphrase: String?, id: UUID) {
        if let passphrase, !passphrase.isEmpty {
            saveSecret(passphrase, key: "ssh-passphrase:\(id.uuidString)")
        } else {
            deleteSecret(key: "ssh-passphrase:\(id.uuidString)")
        }
    }

    static func loadSSHPassphrase(id: UUID) -> String? {
        loadSecret(key: "ssh-passphrase:\(id.uuidString)")
    }

    private static func saveSecret(_ secret: String, key: String) {
        guard let data = secret.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func loadSecret(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteSecret(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
