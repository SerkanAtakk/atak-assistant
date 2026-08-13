import Foundation

/// Sohbet ve mesaj kalıcılığı.
public struct ConversationService: Sendable {

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Sohbetler

    public func recent(limit: Int = 50) async throws -> [Conversation] {
        let rows = try await database.query(
            """
            SELECT * FROM conversation
            WHERE archived = 0
            ORDER BY COALESCE(last_message_at, started_at) DESC
            LIMIT ?;
            """,
            [.int(limit)]
        )
        return rows.compactMap(Self.conversation(from:))
    }

    @discardableResult
    public func create(title: String = "", isPrivate: Bool = false) async throws -> Conversation {
        let conversation = Conversation(title: title, isPrivate: isPrivate)

        // Privacy Mode'da başlık, kimlik ve zaman damgası dâhil sohbet
        // metadatası diske hiç değmez. ChatViewModel bu değeri ve mesajlarını
        // yalnız bellekte tutar; araçların kendi kalıcılığı bundan bağımsızdır.
        guard !isPrivate else { return conversation }

        try await database.run(
            """
            INSERT INTO conversation (id, title, mode, started_at, last_message_at, is_private, archived)
            VALUES (?, ?, 'general', ?, NULL, ?, 0);
            """,
            [
                .uuid(conversation.id), .text(conversation.title),
                .date(conversation.startedAt), .bool(isPrivate),
            ]
        )
        return conversation
    }

    public func rename(_ id: UUID, to title: String) async throws {
        try await database.run(
            "UPDATE conversation SET title = ? WHERE id = ?;",
            [.text(String(title.prefix(120))), .uuid(id)]
        )
    }

    public func delete(_ id: UUID) async throws {
        try await database.run("DELETE FROM conversation WHERE id = ?;", [.uuid(id)])
    }

    // MARK: - Mesajlar

    public func messages(in conversationID: UUID) async throws -> [ChatMessage] {
        let rows = try await database.query(
            "SELECT * FROM message WHERE conversation_id = ? ORDER BY created_at ASC;",
            [.uuid(conversationID)]
        )
        return try rows.map(ChatMessage.init(row:))
    }

    /// Mesajı kaydeder ve sohbetin son mesaj zamanını günceller.
    ///
    /// Privacy Mode'da (`is_private`) diske hiç yazılmaz — spec §36.
    public func append(_ message: ChatMessage, isPrivate: Bool) async throws {
        guard !isPrivate else { return }

        let callsJSON: SQLValue
        if message.toolCalls.isEmpty {
            callsJSON = .null
        } else {
            let data = try JSONEncoder().encode(message.toolCalls)
            callsJSON = .textOrNull(String(data: data, encoding: .utf8))
        }

        try await database.transaction([
            SQLStatement(
                """
                INSERT INTO message
                    (id, conversation_id, role, content, created_at, model,
                     tool_calls_json, tool_call_id, tool_name, is_error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .uuid(message.id), .uuid(message.conversationID),
                    .text(message.role.rawValue), .text(message.text),
                    .date(message.createdAt), .textOrNull(message.model),
                    callsJSON, .textOrNull(message.toolCallID),
                    .textOrNull(message.toolName), .bool(message.isError),
                ]
            ),
            SQLStatement(
                "UPDATE conversation SET last_message_at = ? WHERE id = ?;",
                [.date(message.createdAt), .uuid(message.conversationID)]
            ),
        ])
    }

    /// Akış bittiğinde asistan mesajının son metnini yazar.
    public func updateText(_ id: UUID, text: String, isPrivate: Bool) async throws {
        guard !isPrivate else { return }
        try await database.run(
            "UPDATE message SET content = ? WHERE id = ?;",
            [.text(text), .uuid(id)]
        )
    }

    private static func conversation(from row: Row) -> Conversation? {
        guard let id = row.uuid("id") else { return nil }
        return Conversation(
            id: id,
            title: row.string("title") ?? "",
            startedAt: row.date("started_at") ?? Date(),
            lastMessageAt: row.date("last_message_at"),
            isPrivate: row.bool("is_private") ?? false
        )
    }
}
