import Foundation

/// Anthropic Claude — ücretli, ileride geçiş için hazır.
///
/// Swift'in resmî Anthropic SDK'sı yok; tel formatı (Messages API + SSE)
/// doğrudan uygulanır.
public struct AnthropicProvider: AIProvider {

    public let providerID: AIProviderID = .anthropic
    public let capabilities = AIProviderCapabilities(supportsTools: true, supportsVision: true)

    private let apiKey: String
    private let baseURL: String

    public init(apiKey: String, baseURL: String) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    /// `tool_use` blokları da parça parça gelir (`input_json_delta`).
    private struct PartialCall {
        var id = ""
        var name = ""
        var argumentText = ""
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await openStream(request)
                    var partials: [Int: PartialCall] = [:]
                    var stopReason: String?

                    for try await payload in SSE.payloads(from: bytes) {
                        guard let json = try? JSONValue.decode(payload) else { continue }
                        let type = json["type"]?.stringValue ?? ""

                        switch type {
                        case "content_block_start":
                            let index = json["index"]?.intValue ?? 0
                            if json["content_block"]?["type"]?.stringValue == "tool_use" {
                                partials[index] = PartialCall(
                                    id: json["content_block"]?["id"]?.stringValue ?? "",
                                    name: json["content_block"]?["name"]?.stringValue ?? "",
                                    argumentText: ""
                                )
                            }

                        case "content_block_delta":
                            let index = json["index"]?.intValue ?? 0
                            let delta = json["delta"]
                            switch delta?["type"]?.stringValue {
                            case "text_delta":
                                if let text = delta?["text"]?.stringValue, !text.isEmpty {
                                    continuation.yield(.textDelta(text))
                                }
                            case "input_json_delta":
                                if let fragment = delta?["partial_json"]?.stringValue {
                                    partials[index]?.argumentText += fragment
                                }
                            default:
                                break
                            }

                        case "message_delta":
                            if let reason = json["delta"]?["stop_reason"]?.stringValue {
                                stopReason = reason
                            }

                        case "error":
                            let message = json["error"]?["message"]?.stringValue ?? "bilinmeyen hata"
                            throw ATAKError.provider("Claude: \(message)")

                        default:
                            break
                        }
                    }

                    for (_, partial) in partials.sorted(by: { $0.key < $1.key }) {
                        guard !partial.name.isEmpty else { continue }
                        let arguments = (try? JSONValue.decode(
                            partial.argumentText.isEmpty ? "{}" : partial.argumentText
                        )) ?? .object([:])

                        continuation.yield(.toolCall(AIToolCall(
                            id: partial.id, name: partial.name, arguments: arguments
                        )))
                    }

                    continuation.yield(.finished(Self.stop(stopReason)))
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: StreamTransport.humanize(error, provider: "Claude", baseURL: baseURL)
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Model listesi

    public func availableModels() async throws -> [String] {
        guard let url = URL(string: "\(baseURL)/models?limit=100") else {
            throw ATAKError.provider("Claude adresi geçersiz: \(baseURL)")
        }
        let json = try await StreamTransport.getJSON(
            url: url,
            headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
            provider: "Claude"
        )
        return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }.sorted()
    }

    // MARK: - İstek kurulumu

    private func openStream(_ request: AIRequest) async throws -> URLSession.AsyncBytes {
        guard let url = URL(string: "\(baseURL)/messages") else {
            throw ATAKError.provider("Claude adresi geçersiz: \(baseURL)")
        }

        let urlRequest = try StreamTransport.makeRequest(
            url: url,
            body: body(for: request),
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ]
        )
        return try await StreamTransport.open(urlRequest, provider: "Claude")
    }

    private func body(for request: AIRequest) -> JSONValue {
        var messages: [JSONValue] = []

        for message in request.messages {
            switch message.role {
            case .system:
                continue  // ayrı `system` alanında gider

            case .user:
                messages.append(.object([
                    "role": "user",
                    "content": .array([.object(["type": "text", "text": .string(message.text)])]),
                ]))

            case .assistant:
                var blocks: [JSONValue] = []
                if !message.text.isEmpty {
                    blocks.append(.object(["type": "text", "text": .string(message.text)]))
                }
                for call in message.toolCalls {
                    blocks.append(.object([
                        "type": "tool_use",
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": call.arguments,
                    ]))
                }
                guard !blocks.isEmpty else { continue }
                messages.append(.object(["role": "assistant", "content": .array(blocks)]))

            case .tool:
                messages.append(.object([
                    "role": "user",
                    "content": .array([
                        .object([
                            "type": "tool_result",
                            "tool_use_id": .string(message.toolCallID ?? ""),
                            "content": .string(message.text),
                        ])
                    ]),
                ]))
            }
        }

        var root: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": true,
            "messages": .array(messages),
        ]

        if let system = request.system, !system.isEmpty {
            root["system"] = .string(system)
        }

        if !request.tools.isEmpty {
            root["tools"] = .array(request.tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.parameters,
                ])
            })
        }

        return .object(root)
    }

    private static func stop(_ raw: String?) -> AIStopReason {
        switch raw {
        case "tool_use":   return .toolUse
        case "max_tokens": return .maxTokens
        case "end_turn":   return .endTurn
        case .some(let other): return .other(other)
        case nil:          return .endTurn
        }
    }
}
