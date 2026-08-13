import Foundation

/// ATAK genelinde kullanılan hata tipi.
///
/// Her vaka kullanıcıya gösterilebilir bir Türkçe açıklama taşır; ham teknik
/// ayrıntı `underlying` içinde kalır ve yalnız logda görünür.
public enum ATAKError: Error, LocalizedError, Sendable {
    case database(String)
    case migration(String)
    case notFound(entity: String, id: String)
    case validation(String)
    case permissionDenied(Permission)
    case consentRequired
    case budgetExceeded(String)
    case provider(String)
    /// Sunucu yanıt verdi ama içinden metin/araç çağrısı çıkarılamadı.
    ///
    /// `provider`'dan ayrı tutuluyor: yalnız BU durumda ham teşhis istemeye
    /// değer. HTTP hatalarında (401/404/429) ikinci bir istek atmak boşuna —
    /// kota hatasında ise doğrudan zararlı.
    case emptyResponse(String)
    case cancelled
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .database(let detail):
            return "Veritabanı hatası: \(detail)"
        case .migration(let detail):
            return "Veritabanı güncellenemedi: \(detail)"
        case .notFound(let entity, let id):
            return "\(entity) bulunamadı (\(id))."
        case .validation(let message):
            return message
        case .permissionDenied(let permission):
            // Kullanıcıya yalnız "izin yok" demek onu çıkmaza sokar; iznin
            // nereden verildiği de söylenir.
            var message = "Bu işlem için '\(permission.displayName)' izni gerekiyor."
            if let hint = permission.settingsHint { message += "\n\(hint)" }
            return message
        case .consentRequired:
            return "Bu işlem onayını bekliyor."
        case .budgetExceeded(let detail):
            return "İşlem sınıra takıldı: \(detail)"
        case .provider(let detail):
            return "Yapay zekâ sağlayıcısı hatası: \(detail)"
        case .emptyResponse(let detail):
            return detail
        case .cancelled:
            return "İşlem durduruldu."
        case .unsupported(let detail):
            return "Desteklenmeyen işlem: \(detail)"
        }
    }
}
