import Foundation

public struct VoiceSettings: Sendable, Codable, Equatable {
    /// ATAK yanıtlarını sesli okusun mu.
    public var speakReplies: Bool
    /// Uygulama açılınca ATAK seni sesli karşılasın mı.
    public var greetOnLaunch: Bool

    public init(speakReplies: Bool = true, greetOnLaunch: Bool = true) {
        self.speakReplies = speakReplies
        self.greetOnLaunch = greetOnLaunch
    }

    public static let `default` = VoiceSettings()

    private enum CodingKeys: String, CodingKey {
        case speakReplies, greetOnLaunch
    }

    /// Eksik alanlar varsayılanla dolar — yeni ayar eklemek kayıtlı tercihleri
    /// silmesin (bkz. `AIConfiguration.init(from:)`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.speakReplies = try container.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? true
        self.greetOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .greetOnLaunch) ?? true
    }
}

extension PreferenceKey {
    public static let voice = "voice.settings"
    public static let userName = "user.name"
}

public enum UserIdentity {
    /// macOS hesabından ilk ad tahmini — kullanıcı Ayarlar'dan değiştirebilir.
    ///
    /// Tam ad "Serkan Atak" ise ATAK "Serkan" der; boşsa hitap kullanılmaz.
    public static func defaultFirstName() -> String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "" }

        let first = full.split(separator: " ").first.map(String.init) ?? full
        // Hesap adı tek parça ve tamamen küçük harfliyse (ör. "aliveli")
        // bu bir isim değil kullanıcı adıdır; hitap etme.
        guard first.count > 1, first.first?.isUppercase == true else { return "" }
        return first
    }
}
