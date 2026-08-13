import Foundation

/// ATAK'ın kullanıcı hakkında öğrendiği kalıcı bilgiler (MIMARI §4).
public struct MemoryItem: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case fact           // "Ev adresi İzmir"
        case preference     // "Sabahları toplantı sevmiyor"
        case routine        // "Salı akşamları spor"
        case person         // "Kardeşinin adı Ege"

        public var displayName: String {
            switch self {
            case .fact:       return "Bilgi"
            case .preference: return "Tercih"
            case .routine:    return "Rutin"
            case .person:     return "Kişi"
            }
        }
    }

    /// Bilginin nereden geldiği.
    ///
    /// `readContent` ayrı tutuluyor çünkü okunan içerikten (PDF, web, e-posta)
    /// hafızaya yazmak MIMARI §8 uyarınca yasak; bu değerin veritabanında
    /// görünmesi bir hata işaretidir.
    public enum Source: String, Sendable {
        case userStated     // kullanıcı doğrudan söyledi
        case inferred       // ATAK sohbetten çıkardı
        case readContent    // okunan içerikten türedi — yazılmamalı
    }

    public let id: UUID
    public var kind: Kind
    public var key: String
    public var value: String
    public var confidence: Double
    public var source: Source
    public var pinned: Bool
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        kind: Kind,
        key: String,
        value: String,
        confidence: Double = 1.0,
        source: Source = .userStated,
        pinned: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        useCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.key = key
        self.value = value
        self.confidence = confidence
        self.source = source
        self.pinned = pinned
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }
}

/// Uzun vadeli hafıza (MIMARI §4).
///
/// Hafıza, sohbet geçmişinden ayrıdır: geçmiş pencereye sığdığı kadar
/// yaşar, hafıza kalıcıdır ve kullanıcı tarafından görülüp silinebilir.
public struct MemoryService: Sendable {

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Okuma

    public func all(includeSuperseded: Bool = false) async throws -> [MemoryItem] {
        let sql = includeSuperseded
            ? "SELECT * FROM memory_item ORDER BY pinned DESC, created_at DESC;"
            : "SELECT * FROM memory_item WHERE superseded_by IS NULL ORDER BY pinned DESC, created_at DESC;"
        let rows = try await database.query(sql)
        return rows.compactMap(Self.item(from:))
    }

    public func find(_ id: UUID) async throws -> MemoryItem? {
        guard let row = try await database.queryOne(
            "SELECT * FROM memory_item WHERE id = ?;", [.uuid(id)]
        ) else { return nil }
        return Self.item(from: row)
    }

    /// Türkçe katlamalı FTS5 araması — notlarla aynı kural.
    public func search(_ text: String) async throws -> [MemoryItem] {
        guard let match = FTS.query(from: TurkishText.fold(text)) else {
            return try await all()
        }
        let rows = try await database.query(
            """
            SELECT m.* FROM memory_fts f
            JOIN memory_item m ON m.id = f.memory_id
            WHERE memory_fts MATCH ? AND m.superseded_by IS NULL
            ORDER BY m.pinned DESC, m.created_at DESC;
            """,
            [.text(match)]
        )
        return rows.compactMap(Self.item(from:))
    }

    /// Modele gönderilecek hafıza özeti.
    ///
    /// Tamamı değil: sabitlenenler ve en çok kullanılanlar. Hafıza büyüdükçe
    /// her isteğe eklemek token maliyetini sessizce büyütürdü.
    public func promptDigest(limit: Int = 12) async throws -> String {
        let rows = try await database.query(
            """
            SELECT * FROM memory_item
            WHERE superseded_by IS NULL
            ORDER BY pinned DESC, use_count DESC, created_at DESC
            LIMIT ?;
            """,
            [.int(limit)]
        )
        let items = rows.compactMap(Self.item(from:))
        guard !items.isEmpty else { return "" }
        return items.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
    }

    // MARK: - Yazma

    @discardableResult
    public func remember(
        kind: MemoryItem.Kind = .fact,
        key: String,
        value: String,
        source: MemoryItem.Source = .userStated,
        pinned: Bool = false
    ) async throws -> MemoryItem {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedValue.isEmpty else {
            throw ATAKError.validation("Hafıza kaydı için hem konu hem içerik gerekli.")
        }

        // Okunan içerik hafızaya yazılamaz (MIMARI §8). Bu bir savunma katmanı:
        // araç katmanı hata yapsa bile kayıt buradan geçemez.
        guard source != .readContent else {
            throw ATAKError.validation(
                "Okunan bir içerikten hafızaya yazılamaz. Bu bilgiyi sen söylersen kaydedebilirim."
            )
        }

        let item = MemoryItem(
            kind: kind, key: trimmedKey, value: trimmedValue,
            source: source, pinned: pinned
        )

        // Aynı konuda önceki kayıt silinmez, "geçersiz kılındı" işaretlenir:
        // hafızanın nasıl değiştiği de bilgidir.
        try await database.transaction([
            SQLStatement(
                """
                INSERT INTO memory_item
                    (id, kind, key, value, search_text, confidence, source, pinned,
                     created_at, last_used_at, use_count, superseded_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, NULL);
                """,
                [
                    .uuid(item.id), .text(item.kind.rawValue), .text(trimmedKey),
                    .text(trimmedValue), .text(TurkishText.fold("\(trimmedKey) \(trimmedValue)")),
                    .real(item.confidence), .text(item.source.rawValue),
                    .int(pinned ? 1 : 0), .date(item.createdAt),
                ]
            ),
            SQLStatement(
                """
                UPDATE memory_item SET superseded_by = ?
                WHERE key = ? AND id != ? AND superseded_by IS NULL;
                """,
                [.uuid(item.id), .text(trimmedKey), .uuid(item.id)]
            ),
        ])

        return item
    }

    public func forget(_ id: UUID) async throws {
        try await database.run("DELETE FROM memory_item WHERE id = ?;", [.uuid(id)])
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) async throws {
        try await database.run(
            "UPDATE memory_item SET pinned = ? WHERE id = ?;",
            [.int(pinned ? 1 : 0), .uuid(id)]
        )
    }

    /// Hafızayı tamamen siler (Ayarlar → Veri).
    public func clear() async throws {
        try await database.run("DELETE FROM memory_item;")
    }

    func markUsed(_ id: UUID) async throws {
        try await database.run(
            "UPDATE memory_item SET use_count = use_count + 1, last_used_at = ? WHERE id = ?;",
            [.date(Date()), .uuid(id)]
        )
    }

    // MARK: - Eşleme

    static func item(from row: Row) -> MemoryItem? {
        guard let id = row.uuid("id"),
              let key = row.string("key"),
              let value = row.string("value"),
              let createdAt = row.date("created_at")
        else { return nil }

        return MemoryItem(
            id: id,
            kind: MemoryItem.Kind(rawValue: row.string("kind") ?? "") ?? .fact,
            key: key,
            value: value,
            confidence: row.double("confidence") ?? 1.0,
            source: MemoryItem.Source(rawValue: row.string("source") ?? "") ?? .inferred,
            pinned: row.bool("pinned") ?? false,
            createdAt: createdAt,
            lastUsedAt: row.date("last_used_at"),
            useCount: row.intValue("use_count")
        )
    }
}
