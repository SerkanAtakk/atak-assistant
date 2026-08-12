import Foundation

/// Tarih/süre biçimlendirme.
///
/// `DateFormatter` yerine değer tipi `FormatStyle` kullanılır: `Sendable`,
/// paylaşılan durum yok, aktör sınırlarını serbestçe geçer.
public enum DateFormat {

    public static let locale = Locale(identifier: "tr_TR")

    /// "Bugün 18:00", "Yarın 09:30", "Dün", "12 Ağu", "12 Ağu 2025"
    public static func relativeDay(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Bugün \(time(date))"
        }
        if calendar.isDateInTomorrow(date) {
            return "Yarın \(time(date))"
        }
        if calendar.isDateInYesterday(date) {
            return "Dün \(time(date))"
        }

        // `.year(.omitted)` macOS 15+ olduğu için iki ayrı stil kullanılıyor;
        // hedef macOS 14.
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        if sameYear {
            return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }

    public static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    public static func full(_ date: Date) -> String {
        date.formatted(
            .dateTime.day().month(.wide).year().hour().minute().locale(locale)
        )
    }

    public static func dayAndMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).locale(locale))
    }

    public static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).locale(locale))
    }

    /// "45 dk", "2 sa", "1 sa 30 dk"
    public static func duration(minutes: Int) -> String {
        guard minutes > 0 else { return "0 dk" }
        let hours = minutes / 60
        let remainder = minutes % 60

        switch (hours, remainder) {
        case (0, _):  return "\(remainder) dk"
        case (_, 0):  return "\(hours) sa"
        default:      return "\(hours) sa \(remainder) dk"
        }
    }

    /// Günün saatine göre selamlama (Dashboard).
    public static func greeting(for date: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11:  return "Günaydın"
        case 11..<18: return "İyi günler"
        case 18..<23: return "İyi akşamlar"
        default:      return "İyi geceler"
        }
    }
}
