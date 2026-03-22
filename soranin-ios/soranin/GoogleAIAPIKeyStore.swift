import Foundation
import Security

enum GoogleAIAPIKeyStore {
    private static let service = "com.nin.soranin"
    private static let account = "google_ai_studio_api_key"
    private static let fallbackDefaultsKey = "com.nin.soranin.google_ai_studio_api_key"

    static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let apiKey = String(data: data, encoding: .utf8),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let fallbackKey = UserDefaults.standard.string(forKey: fallbackDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return fallbackKey?.isEmpty == false ? fallbackKey : nil
        }

        return apiKey
    }

    static func hasStoredKey() -> Bool {
        load() != nil
    }

    @discardableResult
    static func save(_ apiKey: String) -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return false
        }

        let query = baseQuery()
        let updatedAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updatedAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackDefaultsKey)
            return true
        }

        if updateStatus == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            if addStatus == errSecSuccess {
                UserDefaults.standard.removeObject(forKey: fallbackDefaultsKey)
                return true
            }
        }

        UserDefaults.standard.set(trimmed, forKey: fallbackDefaultsKey)
        return UserDefaults.standard.string(forKey: fallbackDefaultsKey) == trimmed
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackDefaultsKey)
        let defaultsCleared = UserDefaults.standard.string(forKey: fallbackDefaultsKey) == nil
        return (status == errSecSuccess || status == errSecItemNotFound) && defaultsCleared
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
