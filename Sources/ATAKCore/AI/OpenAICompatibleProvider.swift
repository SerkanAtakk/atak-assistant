import Foundation

/// OpenAI uyumlu `/chat/completions` konuşan her sağlayıcı.
///
/// Tek uygulama ile Groq, OpenRouter, Ollama, Mistral, DeepSeek ve benzerleri
/// desteklenir — aralarındaki fark yalnızca taban adres, anahtar ve model adı.
public struct OpenAICompatibleProvider: AIProvider {

    public let providerID: AIProviderID
    public var capabilities: AIProviderCapabilities {
        AIProviderCatalog.info(for: providerID).capabilities
    }

    private let apiKey: String?
    private let baseURL: String

    public init(providerID: AIProviderID, apiKey: String?, baseURL: String) {
        self.providerID = providerID
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    /// Akış sırasında parça parça gelen araç çağrısı.
    ///
    /// OpenAI protokolünde araç argümanları JSON metni olarak parçalı gelir;
    /// tamamlanmadan ayrıştırılamaz, bu yüzden indekse göre biriktirilir.
    private struct PartialCall {
        var id = ""
        var name = ""
        var argumentText = ""
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        let name = AIProviderCatalog.info(for: providerID).displayName

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Küçük yerel modellerin çoğu araç çağrısı desteklemiyor.
                    // Model reddederse sohbeti kırmak yerine araçsız devam et —
                    // ATAK konuşmaya devam eder, yalnız kayıt oluşturamaz.
                    let bytes: URLSession.AsyncBytes
                    do {
                        bytes = try await openStream(request, providerName: name, includeTools: true)
                    } catch let error where Self.rejectedTools(error) {
                        Log.ai.info("Model araç kullanımını reddetti, araçsız devam ediliyor")
                        bytes = try await openStream(request, providerName: name, includeTools: false)
                    }

                    var partials: [Int: PartialCall] = [:]
                    var finish: String?
                    var usage = AIUsage()

                    for try await payload in SSE.payloads(from: bytes) {
                        guard let json = try? JSONValue.decode(payload) else { continue }

                        if let message = json["error"]?["message"]?.stringValue {
                            throw ATAKError.provider("\(name): \(message)")
                        }

                        // Sağlayıcıların çoğu son parçada kullanım bilgisi gönderir.
                        if let metadata = json["usage"] {
                            if let value = metadata["prompt_tokens"]?.intValue { usage.inputTokens = value }
                            if let value = metadata["completion_tokens"]?.intValue { usage.outputTokens = value }
                        }

                        guard let choice = json["choices"]?[0] else { continue }

                        if let text = choice["delta"]?["content"]?.stringValue, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }

                        for entry in choice["delta"]?["tool_calls"]?.arrayValue ?? [] {
                            let index = entry["index"]?.intValue ?? 0
                            var partial = partials[index] ?? PartialCall()
                            if let id = entry["id"]?.stringValue { partial.id = id }
                            if let function = entry["function"] {
                                if let n = function["name"]?.stringValue { partial.name += n }
                                if let args = function["arguments"]?.stringValue { partial.argumentText += args }
                            }
                            partials[index] = partial
                        }

                        if let reason = choice["finish_reason"]?.stringValue, !reason.isEmpty {
                            finish = reason
                        }
                    }

                    for (_, partial) in partials.sorted(by: { $0.key < $1.key }) {
                        guard !partial.name.isEmpty else { continue }
                        let arguments = (try? JSONValue.decode(
                            partial.argumentText.isEmpty ? "{}" : partial.argumentText
                        )) ?? .object([:])

                        continuation.yield(.toolCall(AIToolCall(
                            id: partial.id.isEmpty ? "call-\(UUID().uuidString.prefix(8))" : partial.id,
                            name: partial.name,
                            arguments: arguments
                        )))
                    }

                    if usage.total > 0 { continuation.yield(.usage(usage)) }
                    continuation.yield(.finished(Self.stopReason(finish, hadToolCalls: !partials.isEmpty)))
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: StreamTransport.humanize(error, provider: name, baseURL: baseURL)
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Model listesi

    public func availableModels() async throws -> [String] {
        let name = AIProviderCatalog.info(for: providerID).displayName
        guard let url = URL(string: "\(baseURL)/models") else {
            throw ATAKError.provider("\(name) adresi geçersiz: \(baseURL)")
        }

        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }

        let json = try await StreamTransport.getJSON(url: url, headers: headers, provider: name)
        let models = (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        return models.sorted()
    }

    /// Akışın ham satırlarını döndürür — ayrıştırma yok, teşhis için.
    public func rawProbe(model: String) async throws -> String {
        let name = AIProviderCatalog.info(for: providerID).displayName
        let probe = AIRequest(
            model: model,
            system: "Kısa cevap ver.",
            messages: [.user("Merhaba de.")],
            maxTokens: 2048
        )

        let bytes = try await openStream(probe, providerName: name, includeTools: false)
        var lines: [String] = []
        var characters = 0

        for try await line in bytes.lines {
            lines.append(line)
            characters += line.count
            if lines.count >= 60 || characters > 4000 { break }
        }

        return lines.isEmpty ? "(sunucu hiç satır döndürmedi)" : lines.joined(separator: "\n")
    }

    // MARK: - İstek kurulumu

    /// Hata modelin araç desteklememesinden mi kaynaklanıyor?
    ///
    /// Sağlayıcılar bunu farklı ifade ediyor; ortak nokta 4xx + "tool"/"function".
    static func rejectedTools(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        let isClientError = text.contains("(400)") || text.contains("(404)") || text.contains("(422)")
        guard isClientError else { return false }
        return text.contains("tool") || text.contains("function calling")
    }

    private func openStream(
        _ request: AIRequest,
        providerName: String,
        includeTools: Bool = true
    ) async throws -> URLSession.AsyncBytes {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw ATAKError.provider("\(providerName) adresi geçersiz: \(baseURL)")
        }

        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        if providerID == .openRouter {
            // OpenRouter istemci tanıtımı ister; sıralamada da yardımcı olur.
            headers["HTTP-Referer"] = "https://github.com/atak"
            headers["X-Title"] = "ATAK"
        }

        let urlRequest = try StreamTransport.makeRequest(
            url: url,
            body: body(for: request, includeTools: includeTools),
            headers: headers
        )
        return try await StreamTransport.open(urlRequest, provider: providerName)
    }

    private func body(for request: AIRequest, includeTools: Bool = true) -> JSONValue {
        var messages: [JSONValue] = []

        if let system = request.system, !system.isEmpty {
            messages.append(.object(["role": "system", "content": .string(system)]))
        }

        for message in request.messages {
            switch message.role {
            case .system:
                messages.append(.object(["role": "system", "content": .string(message.text)]))

            case .user:
                messages.append(.object(["role": "user", "content": .string(message.text)]))

            case .assistant:
                var entry: [String: JSONValue] = ["role": "assistant"]
                entry["content"] = message.text.isEmpty ? .null : .string(message.text)
                if !message.toolCalls.isEmpty {
                    entry["tool_calls"] = .array(message.toolCalls.map { call in
                        .object([
                            "id": .string(call.id),
                            "type": "function",
                            "function": .object([
                                "name": .string(call.name),
                                "arguments": .string(call.arguments.encodedString()),
                            ]),
                        ])
                    })
                }
                messages.append(.object(entry))

            case .tool:
                messages.append(.object([
                    "role": "tool",
                    "tool_call_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.text),
                ]))
            }
        }

        var root: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            "stream": true,
            "max_tokens": .number(Double(request.maxTokens)),
        ]

        if includeTools, !request.tools.isEmpty {
            root["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": "function",
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.parameters,
                    ]),
                ])
            })
        }

        return .object(root)
    }

    private static func stopReason(_ raw: String?, hadToolCalls: Bool) -> AIStopReason {
        switch raw {
        case "tool_calls":              return .toolUse
        case "length":                  return .maxTokens
        case "stop":                    return hadToolCalls ? .toolUse : .endTurn
        case .some(let other) where !other.isEmpty: return .other(other)
        default:                        return hadToolCalls ? .toolUse : .endTurn
        }
    }
}
