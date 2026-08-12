import Foundation
import Security

/// API anahtarlarının tek saklama yeri.
///
/// Güvenlik kuralı (MIMARI §8): anahtar asla UserDefaults, veritabanı, dosya
/// veya loga yazılmaz — yalnız Keychain. Cihaz kilitliyken okunamaz.
public enum Keychain {

    private static let service = "com.serkanatak.atak"

    public static func set(_ value: String, for account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            try remove(account)
            return
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw ATAKError.validation("Anahtar okunamadı.")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ATAKError.validation("Anahtar Keychain'e yazılamadı (\(addStatus)).")
            }
        } else if updateStatus != errSecSuccess {
            throw ATAKError.validation("Anahtar güncellenemedi (\(updateStatus)).")
        }

        Log.security.info("Keychain kaydı güncellendi: \(account, privacy: .public)")
    }

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }

        return value
    }

    public static func remove(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ATAKError.validation("Anahtar silinemedi (\(status)).")
        }
    }

    public static func has(_ account: String) -> Bool {
        get(account) != nil
    }

    /// Her sağlayıcının anahtarı ayrı saklanır — birini değiştirmek diğerini bozmaz.
    public static func account(for provider: AIProviderID) -> String {
        "apikey.\(provider.rawValue)"
    }
}
