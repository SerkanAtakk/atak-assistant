import Foundation

// MARK: - Konuşma tipleri

public enum AIRole: String, Sendable, Codable {
    case system
    case user
    case assistant
    case tool
}

/// Modelin çağırmak istediği araç.
public struct AIToolCall: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct AIMessage: Sendable {
    public var role: AIRole
    public var text: String
    public var toolCalls: [AIToolCall]
    /// `role == .tool` olduğunda hangi çağrıya cevap verildiği.
    public var toolCallID: String?
    public var toolName: String?

    public init(
        role: AIRole,
        text: String = "",
        toolCalls: [AIToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
    }

    public static func user(_ text: String) -> AIMessage { .init(role: .user, text: text) }
    public static func assistant(_ text: String) -> AIMessage { .init(role: .assistant, text: text) }

    public static func toolResult(id: String, name: String, content: String) -> AIMessage {
        .init(role: .tool, text: content, toolCallID: id, toolName: name)
    }
}

/// Modele tanıtılan araç (JSON Schema girdisiyle).
public struct AIToolSpec: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema `object` — `{"type":"object","properties":{...},"required":[...]}`
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct AIRequest: Sendable {
    public var model: String
    public var system: String?
    public var messages: [AIMessage]
    public var tools: [AIToolSpec]
    public var maxTokens: Int
    /// Destekleyen modellerde muhakeme derinliği; `nil` ise sağlayıcı varsayılanı.
    public var thinkingLevel: ThinkingLevel?

    public init(
        model: String,
        system: String? = nil,
        messages: [AIMessage],
        tools: [AIToolSpec] = [],
        maxTokens: Int = 4096,
        thinkingLevel: ThinkingLevel? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.thinkingLevel = thinkingLevel
    }
}

/// Bir isteğin token tüketimi.
public struct AIUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Düşünen modellerin muhakemeye harcadığı token (cevaba dahil değil).
    public var thinkingTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, thinkingTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thinkingTokens = thinkingTokens
    }

    public var total: Int { inputTokens + outputTokens + thinkingTokens }

    public static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage {
        AIUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            thinkingTokens: lhs.thinkingTokens + rhs.thinkingTokens
        )
    }

    public var shortSummary: String {
        var parts = ["\(total) token"]
        if thinkingTokens > 0 { parts.append("\(thinkingTokens) düşünme") }
        return parts.joined(separator: " · ")
    }
}

/// Düşünen modellerde muhakeme derinliği.
public enum ThinkingLevel: String, Sendable, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low:    return "Düşük"
        case .medium: return "Orta"
        case .high:   return "Yüksek"
        }
    }

    public var note: String {
        switch self {
        case .low:    return "En az token harcar; günlük sohbet ve görev oluşturma için yeterli."
        case .medium: return "Dengeli."
        case .high:   return "En iyi muhakeme, en çok token."
        }
    }

    /// Gemini `thinkingLevel` alanı büyük harf bekliyor.
    var wireValue: String { rawValue.uppercased() }
}

public enum AIStopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case other(String)
}

/// Akış olayları. Sağlayıcıya özel tel formatı buraya normalleştirilir.
public enum AIEvent: Sendable {
    case textDelta(String)
    case toolCall(AIToolCall)
    case usage(AIUsage)
    case finished(AIStopReason)
}

// MARK: - Protokol

public struct AIProviderCapabilities: Sendable {
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var supportsStreaming: Bool

    public init(supportsTools: Bool, supportsVision: Bool, supportsStreaming: Bool = true) {
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsStreaming = supportsStreaming
    }
}

/// Tek bir yapay zekâ sağlayıcısı.
///
/// Spec §33: ATAK tek sağlayıcıya kilitlenmez. Yeni sağlayıcı eklemek bu
/// protokolü uygulamak demektir; üst katmanlar (Sohbet, Agent) değişmez.
public protocol AIProvider: Sendable {
    var providerID: AIProviderID { get }
    var capabilities: AIProviderCapabilities { get }
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error>

    /// Bu anahtara gerçekten açık olan model adları.
    ///
    /// Sağlayıcılar model adlarını sık değiştiriyor ve eski adları uyarısız
    /// kapatabiliyor (Gemini 2.5 Flash'ta olduğu gibi). Uygulamaya gömülü
    /// liste bu yüzden tek başına yetmez — asıl kaynak sağlayıcının kendisi.
    func availableModels() async throws -> [String]

    /// Sunucudan dönen HAM yanıtı (ayrıştırılmadan) döndürür.
    ///
    /// Yalnız teşhis içindir: ayrıştırma bir şey üretemediğinde "boş yanıt"
    /// deyip susmak yerine tel üzerinde gerçekte ne geldiğini göstermek için.
    func rawProbe(model: String) async throws -> String
}

extension AIProvider {
    public func availableModels() async throws -> [String] { [] }
    public func rawProbe(model: String) async throws -> String {
        throw ATAKError.unsupported("Bu sağlayıcı için ham teşhis yok.")
    }
}

// MARK: - Sağlayıcı kataloğu

public enum AIProviderID: String, Sendable, CaseIterable, Codable, Identifiable {
    case gemini
    case groq
    case openRouter
    case ollama
    case anthropic

    public var id: String { rawValue }
}

/// Bir sağlayıcının tel protokolü. İki OpenAI-uyumlu sağlayıcı aynı kodu paylaşır.
public enum AIWireProtocol: Sendable {
    case gemini
    case openAICompatible
    case anthropic
}

public struct AIProviderInfo: Sendable, Identifiable {
    public let id: AIProviderID
    public let displayName: String
    public let wire: AIWireProtocol
    public let baseURL: String
    public let requiresKey: Bool
    /// Anahtarın alınacağı sayfa (kullanıcıya gösterilir, otomatik açılmaz).
    public let keyPageURL: String?
    public let defaultModel: String
    /// Öneri listesi — kullanıcı Ayarlar'da serbestçe değiştirebilir.
    public let suggestedModels: [String]
    public let note: String
    public let capabilities: AIProviderCapabilities

    public var isFree: Bool { id != .anthropic }
}

public enum AIProviderCatalog {

    public static func info(for id: AIProviderID) -> AIProviderInfo {
        switch id {
        case .gemini:
            return AIProviderInfo(
                id: .gemini,
                displayName: "Google Gemini",
                wire: .gemini,
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                requiresKey: true,
                keyPageURL: "https://aistudio.google.com/apikey",
                // Google eski modelleri duyurulan tarihten önce, uyarısız
                // yeni kullanıcılara kapatabiliyor (gemini-2.5-flash böyle oldu).
                // Buradaki liste yalnız başlangıç noktası — asıl kaynak
                // Ayarlar'daki "Modelleri getir".
                defaultModel: "gemini-3.6-flash",
                suggestedModels: ["gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite"],
                note: "Ücretsiz katmanı var, Türkçesi iyi, görsel okuyabiliyor.",
                capabilities: .init(supportsTools: true, supportsVision: true)
            )

        case .groq:
            return AIProviderInfo(
                id: .groq,
                displayName: "Groq",
                wire: .openAICompatible,
                baseURL: "https://api.groq.com/openai/v1",
                requiresKey: true,
                keyPageURL: "https://console.groq.com/keys",
                defaultModel: "llama-3.3-70b-versatile",
                suggestedModels: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"],
                note: "Ücretsiz ve çok hızlı. Türkçesi Gemini kadar iyi olmayabilir.",
                capabilities: .init(supportsTools: true, supportsVision: false)
            )

        case .openRouter:
            return AIProviderInfo(
                id: .openRouter,
                displayName: "OpenRouter",
                wire: .openAICompatible,
                baseURL: "https://openrouter.ai/api/v1",
                requiresKey: true,
                keyPageURL: "https://openrouter.ai/keys",
                defaultModel: "deepseek/deepseek-chat-v3-0324:free",
                suggestedModels: [
                    "deepseek/deepseek-chat-v3-0324:free",
                    "meta-llama/llama-3.3-70b-instruct:free",
                ],
                note: "Tek anahtarla çok model. \":free\" ile biten modeller ücretsizdir.",
                capabilities: .init(supportsTools: true, supportsVision: false)
            )

        case .ollama:
            return AIProviderInfo(
                id: .ollama,
                displayName: "Ollama (yerel)",
                wire: .openAICompatible,
                baseURL: "http://localhost:11434/v1",
                requiresKey: false,
                keyPageURL: "https://ollama.com/download",
                defaultModel: "llama3.2",
                suggestedModels: ["llama3.2", "qwen2.5", "mistral"],
                note: "Tamamen yerel ve sınırsız. Veri Mac'ten çıkmaz; model indirmen gerekir.",
                capabilities: .init(supportsTools: true, supportsVision: false)
            )

        case .anthropic:
            return AIProviderInfo(
                id: .anthropic,
                displayName: "Anthropic Claude",
                wire: .anthropic,
                baseURL: "https://api.anthropic.com/v1",
                requiresKey: true,
                keyPageURL: "https://console.anthropic.com/settings/keys",
                defaultModel: "claude-sonnet-5",
                suggestedModels: ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5"],
                note: "Ücretli. En güçlü seçenek; ileride geçmek istersen hazır.",
                capabilities: .init(supportsTools: true, supportsVision: true)
            )
        }
    }

    public static var all: [AIProviderInfo] {
        AIProviderID.allCases.map(info(for:))
    }

    /// Kullanıcı tarafından girilen sunucu adresini güvenlik sınırında doğrular.
    ///
    /// API anahtarı kullanan bulut sağlayıcılarında özel adres kapalıdır. Böylece
    /// bir ayar dosyası elle değiştirilse bile anahtar başka bir sunucuya
    /// gönderilemez. Ollama anahtar kullanmadığı için özel adres destekler; düz
    /// HTTP ise yalnızca gerçek loopback adreslerinde kabul edilir.
    static func validatedBaseURL(
        for id: AIProviderID,
        override: String?
    ) throws -> String {
        let info = info(for: id)
        let custom = override?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        if id != .ollama, custom != nil {
            throw ATAKError.validation(
                "\(info.displayName) için özel sunucu adresine izin verilmiyor. "
                + "API anahtarı yalnızca sağlayıcının resmi sunucusuna gönderilebilir."
            )
        }

        return try validateURL(custom ?? info.baseURL, for: id)
    }

    private static func validateURL(_ value: String, for id: AIProviderID) throws -> String {
        let invalidCharacters = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
        let hasInvalidCharacter = value.unicodeScalars.contains {
            invalidCharacters.contains($0) || $0 == "\\"
        }

        guard !hasInvalidCharacter,
              let components = URLComponents(string: value),
              let url = components.url,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true
        else {
            throw ATAKError.validation(
                "Sunucu adresi geçersiz. Kullanıcı bilgisi, sorgu ve parça içermeyen tam bir URL girin."
            )
        }

        if id == .ollama {
            if scheme == "http" {
                // Foundation sürümüne göre `host`, IPv6 köşeli parantezlerini
                // koruyabilir; iki gösterim de aynı loopback adresidir.
                let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
                guard loopbackHosts.contains(host) else {
                    throw ATAKError.validation(
                        "Ollama için HTTP yalnızca localhost, 127.0.0.1 veya [::1] ile kullanılabilir."
                    )
                }
            } else if scheme != "https" {
                throw ATAKError.validation("Ollama sunucu adresi HTTP veya HTTPS kullanmalıdır.")
            }
        } else {
            let trustedHosts: [AIProviderID: String] = [
                .gemini: "generativelanguage.googleapis.com",
                .groq: "api.groq.com",
                .openRouter: "openrouter.ai",
                .anthropic: "api.anthropic.com",
            ]
            guard scheme == "https",
                  host == trustedHosts[id],
                  components.port == nil || components.port == 443
            else {
                throw ATAKError.validation(
                    "\(info(for: id).displayName) yalnızca resmi HTTPS sunucusuyla kullanılabilir."
                )
            }
        }

        // Sağlayıcılar uç nokta yollarını kendileri ekliyor; sondaki eğik çizgi
        // çift çizgili ve kimi ters vekillerde farklı yorumlanan URL üretmesin.
        var normalized = url.absoluteString
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    /// Ayarlardaki yapılandırmadan çalışır bir sağlayıcı üretir.
    public static func makeProvider(
        for id: AIProviderID,
        apiKey: String?,
        baseURLOverride: String? = nil
    ) throws -> any AIProvider {
        let info = info(for: id)
        let base = try validatedBaseURL(for: id, override: baseURLOverride)

        if info.requiresKey, (apiKey?.isEmpty ?? true) {
            throw ATAKError.provider("\(info.displayName) için API anahtarı gerekiyor.")
        }

        switch info.wire {
        case .gemini:
            return GeminiProvider(apiKey: apiKey ?? "", baseURL: base)
        case .openAICompatible:
            return OpenAICompatibleProvider(providerID: id, apiKey: apiKey, baseURL: base)
        case .anthropic:
            return AnthropicProvider(apiKey: apiKey ?? "", baseURL: base)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
