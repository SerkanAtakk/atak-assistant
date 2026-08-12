import Foundation

/// Google Gemini — varsayılan ücretsiz sağlayıcı.
///
/// Tel formatı diğer ikisinden farklı: mesajlar `contents`, roller
/// `user`/`model`, araçlar `functionDeclarations`. Akış `?alt=sse` ile SSE olur.
public struct GeminiProvider: AIProvider {

    public let providerID: AIProviderID = .gemini
    public let capabilities = AIProviderCapabilities(supportsTools: true, supportsVision: true)

    private let apiKey: String
    private let baseURL: String

    public init(apiKey: String, baseURL: String) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // `thinkingConfig` bu modelde geçersizse istek 400 döner;
                    // sohbeti kırmak yerine bir kez de onsuz denenir.
                    let bytes: URLSession.AsyncBytes
                    do {
                        bytes = try await openStream(request, includeThinking: true)
                    } catch let error where Self.rejectedThinkingConfig(error) {
                        Log.ai.info("thinkingConfig reddedildi, onsuz tekrar deneniyor")
                        bytes = try await openStream(request, includeThinking: false)
                    }

                    var outcome = Outcome()

                    for try await payload in SSE.payloads(from: bytes) {
                        guard let json = try? JSONValue.decode(payload) else { continue }

                        // Sunucu 200 ile de hata döndürebiliyor.
                        if let message = json["error"]?["message"]?.stringValue {
                            throw ATAKError.provider("Gemini: \(message)")
                        }

                        // İstem güvenlik filtresine takıldıysa aday hiç gelmez.
                        if let blocked = json["promptFeedback"]?["blockReason"]?.stringValue {
                            outcome.blockReason = blocked
                        }

                        outcome.absorbUsage(json["usageMetadata"])

                        guard let candidate = json["candidates"]?[0] else { continue }

                        for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
                            // Düşünme parçaları cevap değildir; kullanıcıya gösterilmez.
                            // Ayıklanmazsa modelin iç muhakemesi sohbete sızar.
                            if part["thought"]?.boolValue == true {
                                outcome.sawThoughtPart = true
                                continue
                            }

                            if let text = part["text"]?.stringValue, !text.isEmpty {
                                outcome.sawText = true
                                continuation.yield(.textDelta(text))
                            }
                            if let call = part["functionCall"], let name = call["name"]?.stringValue {
                                outcome.sawToolCall = true
                                continuation.yield(.toolCall(AIToolCall(
                                    // Gemini çağrıya kimlik vermiyor; sonucu eşleştirmek
                                    // için ad yeterli, yine de benzersiz kimlik üretiyoruz.
                                    id: "gemini-\(name)-\(UUID().uuidString.prefix(8))",
                                    name: name,
                                    arguments: call["args"] ?? .object([:])
                                )))
                            }
                        }

                        if let reason = candidate["finishReason"]?.stringValue {
                            outcome.finishReason = reason
                        }
                    }

                    // Hiç içerik üretilmediyse sessizce "boş yanıt" dönmek yerine
                    // sebebini söyle — aksi hâlde kullanıcı nereye bakacağını bilemez.
                    if let diagnosis = outcome.emptyResponseDiagnosis(maxTokens: request.maxTokens) {
                        throw ATAKError.emptyResponse(diagnosis)
                    }

                    if outcome.usage.total > 0 {
                        continuation.yield(.usage(outcome.usage))
                    }
                    continuation.yield(.finished(
                        Self.stopReason(outcome.finishReason, sawToolCall: outcome.sawToolCall)
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: StreamTransport.humanize(error, provider: "Gemini", baseURL: baseURL)
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Model listesi

    /// Yalnızca `streamGenerateContent` destekleyen modelleri döndürür.
    ///
    /// ATAK bu uç noktayı kullanıyor; yalnız yeni Interactions API üzerinden
    /// erişilebilen modeller listeye alınmaz — seçilseler çalışmazlardı.
    public func availableModels() async throws -> [String] {
        guard var components = URLComponents(string: "\(baseURL)/models") else {
            throw ATAKError.provider("Gemini adresi geçersiz: \(baseURL)")
        }
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]

        guard let url = components.url else {
            throw ATAKError.provider("Gemini adresi oluşturulamadı")
        }

        let json = try await StreamTransport.getJSON(
            url: url,
            headers: ["x-goog-api-key": apiKey],
            provider: "Gemini"
        )

        let entries = json["models"]?.arrayValue ?? []

        func shortName(_ entry: JSONValue) -> String? {
            guard let name = entry["name"]?.stringValue else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }

        let allNames = entries.compactMap(shortName)
        let streamable = entries.compactMap { entry -> String? in
            let methods = (entry["supportedGenerationMethods"]?.arrayValue ?? [])
                .compactMap(\.stringValue)
            guard methods.contains("streamGenerateContent") else { return nil }
            return shortName(entry)
        }

        // Süzme hiçbir şey bırakmazsa alan adı değişmiş olabilir; kullanıcıyı
        // boş listeyle baş başa bırakmaktansa tüm modelleri göster.
        return (streamable.isEmpty ? allNames : streamable).sorted()
    }

    // MARK: - Ham teşhis

    /// Akışın ham satırlarını döndürür — ayrıştırma yok.
    public func rawProbe(model: String) async throws -> String {
        let probe = AIRequest(
            model: model,
            system: "Kısa cevap ver.",
            messages: [.user("Merhaba de.")],
            maxTokens: 2048
        )

        let bytes = try await openStream(probe, includeThinking: false)
        var lines: [String] = []
        var characters = 0

        for try await line in bytes.lines {
            lines.append(line)
            characters += line.count
            if lines.count >= 60 || characters > 4000 { break }
        }

        return lines.isEmpty
            ? "(sunucu hiç satır döndürmedi)"
            : lines.joined(separator: "\n")
    }

    // MARK: - İstek kurulumu

    private func openStream(
        _ request: AIRequest,
        includeThinking: Bool
    ) async throws -> URLSession.AsyncBytes {
        guard var components = URLComponents(
            string: "\(baseURL)/models/\(request.model):streamGenerateContent"
        ) else {
            throw ATAKError.provider("Gemini adresi geçersiz: \(baseURL)")
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]

        guard let url = components.url else {
            throw ATAKError.provider("Gemini adresi oluşturulamadı")
        }

        let urlRequest = try StreamTransport.makeRequest(
            url: url,
            body: body(for: request, includeThinking: includeThinking),
            // Anahtar başlıkta gider — URL'de gitseydi loglara ve geçmişe sızardı.
            headers: ["x-goog-api-key": apiKey]
        )
        return try await StreamTransport.open(urlRequest, provider: "Gemini")
    }

    /// Hata `thinkingConfig` alanından mı kaynaklanıyor?
    static func rejectedThinkingConfig(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        guard text.contains("(400)") else { return false }
        return text.contains("thinking") || text.contains("thinkinglevel")
    }

    /// `thinkingConfig` yalnız Gemini 3 ailesinde geçerli; eski modellere
    /// gönderilirse istek reddedilir.
    static func supportsThinkingLevel(_ model: String) -> Bool {
        model.lowercased().hasPrefix("gemini-3")
    }

    private func body(for request: AIRequest, includeThinking: Bool) -> JSONValue {
        var generation: [String: JSONValue] = [
            "maxOutputTokens": .number(Double(request.maxTokens))
        ]

        if includeThinking,
           let level = request.thinkingLevel,
           Self.supportsThinkingLevel(request.model) {
            generation["thinkingConfig"] = .object(["thinkingLevel": .string(level.wireValue)])
        }

        var root: [String: JSONValue] = [
            "contents": .array(Self.contents(from: request.messages)),
            "generationConfig": .object(generation),
        ]

        if let system = request.system, !system.isEmpty {
            root["systemInstruction"] = .object([
                "parts": .array([.object(["text": .string(system)])])
            ])
        }

        if !request.tools.isEmpty {
            root["tools"] = .array([
                .object([
                    "functionDeclarations": .array(request.tools.map { tool in
                        .object([
                            "name": .string(tool.name),
                            "description": .string(tool.description),
                            "parameters": tool.parameters,
                        ])
                    })
                ])
            ])
        }

        return .object(root)
    }

    /// ATAK mesajlarını Gemini `contents` dizisine çevirir.
    ///
    /// Gemini yalnız `user` ve `model` rollerini tanır; araç sonuçları
    /// `functionResponse` parçası olarak kullanıcı turunda taşınır.
    static func contents(from messages: [AIMessage]) -> [JSONValue] {
        var result: [JSONValue] = []

        for message in messages {
            switch message.role {
            case .system:
                continue  // systemInstruction alanında ayrıca gönderiliyor

            case .user:
                result.append(.object([
                    "role": "user",
                    "parts": .array([.object(["text": .string(message.text)])]),
                ]))

            case .assistant:
                var parts: [JSONValue] = []
                if !message.text.isEmpty {
                    parts.append(.object(["text": .string(message.text)]))
                }
                for call in message.toolCalls {
                    parts.append(.object([
                        "functionCall": .object([
                            "name": .string(call.name),
                            "args": call.arguments,
                        ])
                    ]))
                }
                guard !parts.isEmpty else { continue }
                result.append(.object(["role": "model", "parts": .array(parts)]))

            case .tool:
                result.append(.object([
                    "role": "user",
                    "parts": .array([
                        .object([
                            "functionResponse": .object([
                                "name": .string(message.toolName ?? "tool"),
                                "response": .object(["result": .string(message.text)]),
                            ])
                        ])
                    ]),
                ]))
            }
        }

        return result
    }

    static func stopReason(_ raw: String?, sawToolCall: Bool) -> AIStopReason {
        switch raw?.uppercased() {
        case "STOP", nil:  return sawToolCall ? .toolUse : .endTurn
        case "MAX_TOKENS": return .maxTokens
        case .some(let other): return .other(other)
        }
    }

    /// Akış boyunca biriken teşhis bilgisi.
    ///
    /// Gemini 3 modelleri düşünüyor ve düşünme çıktı token bütçesinden yiyor;
    /// bütçe küçükse hiç cevap üretilmeden akış biter. O durumda "boş yanıt"
    /// demek kullanıcıyı kör bırakır — sebebi burada toplanıp söyleniyor.
    struct Outcome {
        var sawText = false
        var sawToolCall = false
        var sawThoughtPart = false
        var finishReason: String?
        var blockReason: String?
        var usage = AIUsage()

        var thoughtsTokens: Int? { usage.thinkingTokens > 0 ? usage.thinkingTokens : nil }

        mutating func absorbUsage(_ metadata: JSONValue?) {
            guard let metadata else { return }
            // Her parçada kümülatif geliyor; son değer geçerli.
            if let value = metadata["promptTokenCount"]?.intValue { usage.inputTokens = value }
            if let value = metadata["candidatesTokenCount"]?.intValue { usage.outputTokens = value }
            if let value = metadata["thoughtsTokenCount"]?.intValue { usage.thinkingTokens = value }
        }

        /// İçerik üretilmediyse sebebini açıklayan mesaj; üretildiyse `nil`.
        func emptyResponseDiagnosis(maxTokens: Int) -> String? {
            guard !sawText, !sawToolCall else { return nil }

            if let blockReason {
                return "Gemini isteği güvenlik filtresine takıldı (\(blockReason))."
            }

            if finishReason?.uppercased() == "MAX_TOKENS" || sawThoughtPart {
                let spent = thoughtsTokens.map { " Düşünmeye \($0) token gitti." } ?? ""
                return "Model yalnızca düşündü, cevaba yer kalmadı.\(spent) "
                    + "Şu anki sınır \(maxTokens) token — Ayarlar'dan artırabilir "
                    + "veya daha az düşünen bir model seçebilirsin (ör. flash-lite)."
            }

            if let finishReason, finishReason.uppercased() != "STOP" {
                return "Gemini yanıt üretmeden durdu (finishReason: \(finishReason))."
            }

            return "Gemini boş yanıt döndü. Model adını kontrol et."
        }
    }
}
