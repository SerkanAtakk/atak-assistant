import Foundation

/// ATAK'ın yaptığı işlerin denetim defteri ve geri alma kaynağı (MIMARI §5).
///
/// Sohbet metni modelin *iddiasıdır*; bu tablo gerçekte çalışan işlemdir.
/// İkisinin ayrı tutulması, "yaptım" deyip yapmamış bir modeli yakalamanın
/// tek yolu.
public struct ActionLogService: Sendable {

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Yazma

    public func record(_ action: AssistantAction) async throws {
        let output = ActionOutput(summary: action.summary, undo: action.undo)
        let outputJSON = (try? JSONEncoder().encode(output))
            .flatMap { String(data: $0, encoding: .utf8) }

        try await database.run(
            """
            INSERT INTO assistant_action
                (id, conversation_id, tool_id, input_json, output_json, risk_level,
                 required_consent, consent_granted_at, status, verified, error,
                 started_at, ended_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .uuid(action.id), .uuidOrNull(action.conversationID), .text(action.toolID),
                .text(action.input), .textOrNull(outputJSON), .text(action.risk.rawValue),
                .int(action.requiredConsent ? 1 : 0), .dateOrNull(action.consentGrantedAt),
                .text(action.status.rawValue), .int(action.verified ? 1 : 0),
                .textOrNull(action.error),
                .date(action.startedAt), .dateOrNull(action.endedAt),
            ]
        )
    }

    // MARK: - Okuma

    public func recent(limit: Int = 50) async throws -> [AssistantAction] {
        let rows = try await database.query(
            "SELECT * FROM assistant_action ORDER BY started_at DESC LIMIT ?;",
            [.int(limit)]
        )
        return rows.compactMap(Self.action(from:))
    }

    /// Geri alınabilecek en son iş.
    ///
    /// Geri alınmış bir iş bir daha geri alınamamalı; bunun için kayıt
    /// silinmiyor, `status` alanı `cancelled`'a çekiliyor — defter tarihî
    /// kayıt olduğu için geçmiş asla silinmez.
    public func lastUndoable() async throws -> AssistantAction? {
        let rows = try await database.query(
            """
            SELECT * FROM assistant_action
            WHERE status = 'succeeded' AND output_json IS NOT NULL
            ORDER BY started_at DESC
            LIMIT 20;
            """
        )
        return rows.compactMap(Self.action(from:)).first(where: \.isUndoable)
    }

    /// Geri alınan işi defterde işaretler.
    public func markUndone(_ id: UUID) async throws {
        try await database.run(
            "UPDATE assistant_action SET status = ?, ended_at = ? WHERE id = ?;",
            [.text(ActionStatus.cancelled.rawValue), .date(Date()), .uuid(id)]
        )
    }

    public func counts() async throws -> (total: Int, failed: Int, denied: Int) {
        let rows = try await database.query(
            """
            SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed,
                SUM(CASE WHEN status = 'denied' THEN 1 ELSE 0 END) AS denied
            FROM assistant_action;
            """
        )
        guard let row = rows.first else { return (0, 0, 0) }
        return (row.intValue("total"), row.intValue("failed"), row.intValue("denied"))
    }

    /// Denetim defterini tamamen siler (Ayarlar → Veri).
    public func clear() async throws {
        try await database.run("DELETE FROM assistant_action;")
    }

    // MARK: - Eşleme

    static func action(from row: Row) -> AssistantAction? {
        guard let id = row.uuid("id"),
              let toolID = row.string("tool_id"),
              let startedAt = row.date("started_at")
        else { return nil }

        var summary = ""
        var undo: UndoToken?
        if let json = row.string("output_json"),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ActionOutput.self, from: data) {
            summary = decoded.summary
            undo = decoded.undo
        }

        return AssistantAction(
            id: id,
            conversationID: row.uuid("conversation_id"),
            toolID: toolID,
            input: row.string("input_json") ?? "{}",
            summary: summary,
            undo: undo,
            risk: RiskLevel(rawValue: row.string("risk_level") ?? "") ?? .low,
            requiredConsent: row.bool("required_consent") ?? false,
            consentGrantedAt: row.date("consent_granted_at"),
            status: ActionStatus(rawValue: row.string("status") ?? "") ?? .failed,
            verified: row.bool("verified") ?? false,
            error: row.string("error"),
            startedAt: startedAt,
            endedAt: row.date("ended_at")
        )
    }
}
