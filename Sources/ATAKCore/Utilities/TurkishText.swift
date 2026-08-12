import Foundation

/// Türkçe metni arama için normalleştirir.
///
/// Neden gerekli: SQLite FTS5'in `unicode61 remove_diacritics` seçeneği yalnız
/// *aksanlı* harfleri sadeleştirir. Türkçe'deki **ı** (noktasız i) bir aksanlı
/// harf değil, ayrı bir temel harftir — bu yüzden "çalışma" indekste "calısma"
/// olur ve kullanıcı "calisma" yazınca hiçbir şey bulamaz. Aynı sorun **İ**
/// için de geçerlidir.
///
/// Çözüm: metni yazarken ve ararken aynı fonksiyondan geçirmek. Böylece
/// "Çalışma", "calisma", "ÇALIŞMA" ve "calışma" hepsi eşleşir.
public enum TurkishText {

    private static let foldMap: [Character: Character] = [
        "ı": "i", "İ": "i", "I": "i", "i": "i",
        "ş": "s", "Ş": "s",
        "ğ": "g", "Ğ": "g",
        "ü": "u", "Ü": "u",
        "ö": "o", "Ö": "o",
        "ç": "c", "Ç": "c",
        "â": "a", "Â": "a",
        "î": "i", "Î": "i",
        "û": "u", "Û": "u",
    ]

    /// Aramada kullanılacak sadeleştirilmiş biçim.
    ///
    /// `lowercased()` tek başına yetmez: Türkçe yerelinde "I" → "ı" olur ve
    /// sorun devam eder, Türkçe dışı yerelde "İ" → "i̇" (i + birleşen nokta)
    /// olur ve token bozulur. Bu yüzden eşleme açıkça yapılır.
    public static func fold(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        for character in text {
            if let mapped = foldMap[character] {
                result.append(mapped)
            } else {
                result.append(contentsOf: character.lowercased())
            }
        }
        return result
    }

    /// Bir notun/kaydın aranabilir gövdesini üretir.
    public static func searchText(_ parts: String...) -> String {
        fold(parts.filter { !$0.isEmpty }.joined(separator: " "))
    }
}
