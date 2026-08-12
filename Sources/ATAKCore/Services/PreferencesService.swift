import Foundation

/// `user_preference` tablosu üzerinden anahtar/değer ayar saklama.
///
/// Sırlar buraya YAZILMAZ — onlar Keychain'de (bkz. `Keychain`).
public struct PreferencesService: Sendable {

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func string(_ key: String) async throws -> String? {
        let row = try await database.queryOne(
            "SELECT value_json FROM user_preference WHERE key = ?;", [.text(key)]
        )
        return row?.string("value_json")
    }

    public func setString(_ value: String?, for key: String) async throws {
        guard let value else {
            try await database.run("DELETE FROM user_preference WHERE key = ?;", [.text(key)])
            return
        }
        try await database.run(
            """
            INSERT INTO user_preference (key, value_json, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json,
                                           updated_at = excluded.updated_at;
            """,
            [.text(key), .text(value), .date(Date())]
        )
    }

    public func decode<T: Decodable>(_ type: T.Type, for key: String) async throws -> T? {
        guard let raw = try await string(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func encode<T: Encodable>(_ value: T, for key: String) async throws {
        let data = try JSONEncoder().encode(value)
        try await setString(String(data: data, encoding: .utf8), for: key)
    }
}

public enum PreferenceKey {
    public static let aiConfiguration = "ai.configuration"
    public static let theme = "appearance.theme"
    public static let onboardingCompleted = "onboarding.completed"
}
