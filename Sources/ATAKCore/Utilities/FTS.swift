import Foundation

/// FTS5 sorgu üretimi.
///
/// Notlar ve hafıza aynı arama davranışını paylaşıyor; kural tek yerde
/// durmazsa biri düzeltilip diğeri unutulur.
public enum FTS {

    /// Kullanıcı metnini güvenli bir FTS5 MATCH ifadesine çevirir.
    ///
    /// Tırnak kaçışı yapılmazsa `"` içeren arama FTS5 sözdizimini bozar;
    /// her terim tırnaklanır ve önek araması için `*` eklenir. Aranacak
    /// terim kalmazsa `nil` döner — çağıran bunu "hepsini getir" olarak
    /// yorumlar.
    public static func query(from input: String) -> String? {
        let terms = input
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return nil }

        return terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }
}
