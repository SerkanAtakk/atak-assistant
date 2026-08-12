import Foundation

public struct Conversation: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var lastMessageAt: Date?
    public var isPrivate: Bool

    public init(
        id: UUID = UUID(),
        title: String = "",
        startedAt: Date = Date(),
        lastMessageAt: Date? = nil,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.lastMessageAt = lastMessageAt
        self.isPrivate = isPrivate
    }

    public var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Yeni sohbet" : title
    }
}

/// Sohbetteki tek mesaj — kalıcı hâli.
///
/// `AIMessage` sağlayıcıya giden geçici biçim; bu ise veritabanındaki kayıt.
/// İkisi ayrı tutuluyor çünkü bu kaydın kimliği, zamanı ve hata durumu var.
public struct ChatMessage: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var conversationID: UUID
    public var role: AIRole
    public var text: String
    public var toolCalls: [AIToolCall]
    public var toolCallID: String?
    public var toolName: String?
    public var isError: Bool
    public var model: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: AIRole,
        text: String = "",
        toolCalls: [AIToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        isError: Bool = false,
        model: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.isError = isError
        self.model = model
        self.createdAt = createdAt
    }

    /// Sağlayıcıya gönderilecek biçim.
    public var asAIMessage: AIMessage {
        AIMessage(
            role: role,
            text: text,
            toolCalls: toolCalls,
            toolCallID: toolCallID,
            toolName: toolName
        )
    }

    /// Araç kayıtları sohbet balonu olarak değil, satır içi rozet olarak gösterilir.
    public var isVisibleInTranscript: Bool {
        switch role {
        case .user:      return !text.isEmpty
        case .assistant: return !text.isEmpty || !toolCalls.isEmpty
        case .tool:      return false
        case .system:    return false
        }
    }
}

extension ChatMessage {
    init(row: Row) throws {
        guard let id = row.uuid("id"), let conversationID = row.uuid("conversation_id") else {
            throw ATAKError.database("message satırı okunamadı")
        }

        let calls: [AIToolCall]
        if let raw = row.string("tool_calls_json"), let data = raw.data(using: .utf8) {
            calls = (try? JSONDecoder().decode([AIToolCall].self, from: data)) ?? []
        } else {
            calls = []
        }

        self.init(
            id: id,
            conversationID: conversationID,
            role: AIRole(rawValue: row.string("role") ?? "") ?? .assistant,
            text: row.string("content") ?? "",
            toolCalls: calls,
            toolCallID: row.string("tool_call_id"),
            toolName: row.string("tool_name"),
            isError: row.bool("is_error") ?? false,
            model: row.string("model"),
            createdAt: row.date("created_at") ?? Date()
        )
    }
}
