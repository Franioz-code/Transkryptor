import Foundation
import Security

/// Bezpieczne przechowywanie klucza Anthropic API w Keychain (nie w UserDefaults, nie w kodzie).
enum KeychainService {
    private static let service = "com.franioz.Transkryptor"
    private static let account = "anthropic-api-key"

    // Cache w pamięci — Keychain czytamy raz na uruchomienie, żeby nie wywoływać
    // monitu systemowego przy każdym sprawdzeniu obecności klucza (np. w renderze UI).
    private static var didLoad = false
    private static var cachedKey: String?

    static func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { deleteAPIKey(); return }
        guard let data = trimmed.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
        cachedKey = trimmed
        didLoad = true
    }

    static func loadAPIKey() -> String? {
        if didLoad { return cachedKey }
        let key = readFromKeychain()
        cachedKey = key
        didLoad = true
        return key
    }

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        cachedKey = nil
        didLoad = true
    }

    static var hasAPIKey: Bool {
        guard let key = loadAPIKey() else { return false }
        return !key.isEmpty
    }
}
