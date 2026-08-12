import Foundation

public struct Note: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var body: String
    public var projectID: UUID?
    public var folder: String
    public var createdAt: Date
    public var updatedAt: Date
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        projectID: UUID? = nil,
        folder: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.projectID = projectID
        self.folder = folder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
    }

    /// Listede gösterilecek başlık; boşsa gövdenin ilk satırından türetilir.
    public var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        let firstLine = body
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? "Başlıksız not" : String(firstLine.prefix(60))
    }

    public var preview: String {
        body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension Note {
    init(row: Row) throws {
        guard let id = row.uuid("id") else {
            throw ATAKError.database("note satırı okunamadı")
        }
        self.init(
            id: id,
            title: row.string("title") ?? "",
            body: row.string("body") ?? "",
            projectID: row.uuid("project_id"),
            folder: row.string("folder") ?? "",
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date(),
            tags: []
        )
    }
}
