import Foundation

/// Server-Sent Events ayrıştırıcısı.
///
/// Üç sağlayıcının üçü de SSE kullanıyor (`data: {...}` satırları), sadece
/// gövde şekilleri farklı. Bu yüzden ayrıştırma tek yerde toplanır.
enum SSE {

    /// Satır satır beslenen SSE durum makinesi.
    ///
    /// Ağdan ayrılmış saf mantık: testler satırları doğrudan verip çıktıyı
    /// doğrulayabiliyor — akış davranışını sınamak için gerçek bir HTTP
    /// bağlantısı gerekmiyor.
    struct Parser {
        enum Output: Equatable {
            case none
            case payload(String)
            case done
        }

        private var buffer = ""

        mutating func consume(line: String) -> Output {
            if line.isEmpty {
                // Olay sınırı: biriken veriyi yayınla.
                return flush().map(Output.payload) ?? .none
            }

            if line.hasPrefix(":") { return .none }  // yorum / heartbeat

            guard let colon = line.firstIndex(of: ":") else { return .none }
            guard String(line[line.startIndex..<colon]) == "data" else { return .none }

            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }

            if value == "[DONE]" { return .done }

            // Gemini olayları arasında boş satır GÖNDERMİYOR: iki `data:` satırı
            // arka arkaya geliyor. Yalnız boş satırda yayınlasaydık (SSE
            // spesifikasyonunun harfi) iki JSON tek tamponda birleşir, geçerli
            // JSON olmaktan çıkar ve yanıt sessizce kaybolurdu.
            // Bu yüzden: elimizdeki tampon tek başına geçerli JSON ise ve yeni
            // bir `data:` satırı geldiyse, bu yeni bir olaydır — öncekini yayınla.
            if !buffer.isEmpty, Self.isCompleteJSON(buffer) {
                let ready = buffer
                buffer = value
                return .payload(ready)
            }

            buffer += buffer.isEmpty ? value : "\n" + value
            return .none
        }

        /// Tamponun tek başına ayrıştırılabilir bir JSON değeri olup olmadığı.
        /// Çok satırlı `data:` blokları (spesifikasyona uyan sağlayıcılar)
        /// bu sayede hâlâ doğru birleştirilir.
        private static func isCompleteJSON(_ text: String) -> Bool {
            (try? JSONValue.decode(text)) != nil
        }

        /// Akış bitince artakalan veriyi verir.
        mutating func flush() -> String? {
            guard !buffer.isEmpty else { return nil }
            defer { buffer = "" }
            return buffer
        }
    }

    /// HTTP gövdesindeki bayt akışını `data:` yüklerine çevirir.
    static func payloads(
        from bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = Parser()
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        switch parser.consume(line: line) {
                        case .none:
                            continue
                        case .payload(let payload):
                            continuation.yield(payload)
                        case .done:
                            if let remainder = parser.flush() { continuation.yield(remainder) }
                            continuation.finish()
                            return
                        }
                    }

                    if let remainder = parser.flush() { continuation.yield(remainder) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 429 hız sınırı mı, bakiye/kredi bitmesi mi?
    ///
    /// İkisi aynı HTTP kodunu döndürüyor ama çözümleri zıt: hız sınırında
    /// beklemek yeter, bakiye bittiyse beklemek hiçbir şeyi değiştirmez.
    static func isBillingExhausted(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        let signals = ["prepayment", "credits are depleted", "depleted", "billing", "insufficient"]
        return signals.contains { lowered.contains($0) }
    }

    static let billingHint =
        "Bu bir hız sınırı DEĞİL — hesabının bakiyesi/kredisi bitmiş. Beklemek çözmez. "
        + "Ya Google AI Studio'dan (ai.studio/projects) faturalandırmayı düzelt, "
        + "ya da Ayarlar'dan başka bir sağlayıcıya geç: Groq ve OpenRouter ücretsiz katman sunuyor, "
        + "Ollama ise tamamen yerel çalışır (anahtar da kota da gerekmez)."

    static let rateLimitHint =
        "Ücretsiz katman hız sınırına takıldın. Bu sınır hem dakikalık hem günlük olabiliyor — "
        + "birkaç dakika sonra çalışırsa dakikalıktı, çalışmazsa günlük kota bitmiştir. "
        + "Beklemek istemiyorsan Ayarlar'dan sağlayıcıyı değiştir: Groq ve OpenRouter da "
        + "ücretsiz ve ayrı kotaları var, Ollama ise tamamen yerel çalışır (kota yok)."

    /// HTTP hatalarını okunabilir mesaja çevirir.
    ///
    /// Sağlayıcılar hata gövdesinde farklı alanlar kullanıyor; hepsinde
    /// işe yarayan bir metin bulmaya çalışır.
    static func describeFailure(status: Int, body: Data, provider: String) -> ATAKError {
        var detail = String(data: body, encoding: .utf8) ?? ""

        if let json = try? JSONValue.decode(body) {
            let candidates: [String?] = [
                json["error"]?["message"]?.stringValue,
                json["error"]?.stringValue,
                json["message"]?.stringValue,
                json[0]?["error"]?["message"]?.stringValue,
            ]
            if let found = candidates.compactMap({ $0 }).first, !found.isEmpty {
                detail = found
            }
        }

        if detail.count > 300 { detail = String(detail.prefix(300)) + "…" }

        let hint: String
        switch status {
        case 401, 403:
            hint = "API anahtarı geçersiz veya yetkisiz görünüyor. Ayarlar'dan kontrol et."
        case 404:
            hint = "Model adı bulunamadı. Ayarlar'dan model adını kontrol et."
        case 429:
            // İki farklı 429 var ve tavsiyeleri zıt:
            // hız sınırında beklemek işe yarar, bakiye bitmesinde YARAMAZ.
            hint = isBillingExhausted(detail) ? Self.billingHint : Self.rateLimitHint
        case 500...599:
            hint = "Sağlayıcı tarafında geçici bir sorun var. Birazdan tekrar dene."
        default:
            hint = ""
        }

        let message = [
            "\(provider) hatası (\(status))",
            detail.isEmpty ? nil : detail,
            hint.isEmpty ? nil : hint,
        ].compactMap { $0 }.joined(separator: "\n")

        return ATAKError.provider(message)
    }
}
