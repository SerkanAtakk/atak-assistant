import Foundation

/// ATAK'ın ihtiyaç duyabileceği izinler (MIMARI §7).
///
/// İki katman vardır: bir kısmı macOS TCC'ye karşılık gelir, bir kısmı
/// yalnızca ATAK'ın kendi iç kuralıdır (macOS'un sormadığı, daha ince ayrım).
public enum Permission: String, Sendable, CaseIterable, Codable {
    case calendar
    case reminders
    case microphone
    case speechRecognition
    case notifications
    case files          // kapsam: yalnız kullanıcının seçtiği klasörler
    case automation     // uygulama açma, Finder'da gösterme
    case network        // web araması / sağlayıcı çağrısı
    case email          // v0.3
    case terminal       // v0.3, yüksek risk
    case proactive      // ATAK'ın kendiliğinden bildirim göndermesi

    public var displayName: String {
        switch self {
        case .calendar:          return "Takvim"
        case .reminders:         return "Hatırlatıcılar"
        case .microphone:        return "Mikrofon"
        case .speechRecognition: return "Konuşma Tanıma"
        case .notifications:     return "Bildirimler"
        case .files:             return "Dosyalar"
        case .automation:        return "Uygulama Kontrolü"
        case .network:           return "İnternet Erişimi"
        case .email:             return "E-posta"
        case .terminal:          return "Terminal"
        case .proactive:         return "Proaktif Öneriler"
        }
    }

    /// İzin istenirken kullanıcıya gösterilen gerekçe. Boş gerekçeyle izin istenmez.
    public var rationale: String {
        switch self {
        case .calendar:
            return "Gününü planlamak ve \"cuma öğleden sonra boş muyum?\" gibi soruları cevaplamak için takvimini okur. Etkinlik oluşturmak ayrıca onayına tabidir."
        case .reminders:
            return "Görevlerini Apple Hatırlatıcılar ile eşleştirmek için gerekir."
        case .microphone:
            return "ATAK ile sesli konuşabilmen için gerekir. Sürekli dinleme varsayılan olarak kapalıdır."
        case .speechRecognition:
            return "Söylediklerini metne çevirmek için gerekir."
        case .notifications:
            return "Timer bitişi ve yaklaşan işler için bildirim gönderir."
        case .files:
            return "Yalnızca senin seçtiğin klasörlerdeki dosyaları arar ve okur. Tüm diske erişimi yoktur."
        case .automation:
            return "Uygulama açmak veya bir dosyayı Finder'da göstermek için gerekir."
        case .network:
            return "Yapay zekâ sağlayıcısına bağlanmak ve web araması yapmak için gerekir."
        case .email:
            return "E-postalarını okuyup özetlemek için gerekir. Gönderme her zaman ayrı onay ister."
        case .terminal:
            return "Geliştirici modunda komut çalıştırmak için gerekir. Her komut ayrı onay ister."
        case .proactive:
            return "Sen sormadan da faydalı hatırlatmalar gösterebilmesi için gerekir. İstediğin an kapatabilirsin."
        }
    }

    /// İzin reddedilmişse kullanıcının onu nereden açacağı.
    ///
    /// macOS bir izni bir kez reddettikten sonra uygulamanın tekrar sorma
    /// hakkı yoktur; bu yüzden hata mesajının kendisi yol tarif etmeli.
    public var settingsHint: String? {
        guard isSystemLevel else { return nil }
        let pane: String
        switch self {
        case .calendar:          pane = "Takvimler"
        case .reminders:         pane = "Hatırlatıcılar"
        case .microphone:        pane = "Mikrofon"
        case .speechRecognition: pane = "Konuşma Tanıma"
        case .notifications:     pane = "Bildirimler"
        case .automation:        pane = "Otomasyon"
        default:                 return nil
        }
        return "Sistem Ayarları → Gizlilik ve Güvenlik → \(pane) bölümünden ATAK'a izin verebilirsin."
    }

    /// macOS'un kendi izin sistemine (TCC) karşılık geliyor mu?
    public var isSystemLevel: Bool {
        switch self {
        case .calendar, .reminders, .microphone, .speechRecognition, .notifications, .automation:
            return true
        case .files, .network, .email, .terminal, .proactive:
            return false
        }
    }
}
