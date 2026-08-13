import Foundation

/// Not CRUD + FTS5 tam metin arama.
public struct NoteService: Sendable {

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Okuma

    public func all(projectID: UUID? = nil) async throws -> [Note] {
        let sql: String
        let parameters: [SQLValue]
        if let projectID {
            sql = "SELECT * FROM note WHERE project_id = ? ORDER BY updated_at DESC;"
            parameters = [.uuid(projectID)]
        } else {
            sql = "SELECT * FROM note ORDER BY updated_at DESC;"
            parameters = []
        }
        let rows = try await database.query(sql, parameters)
        return try rows.map(Note.init(row:))
    }

    public func find(_ id: UUID) async throws -> Note? {
        guard let row = try await database.queryOne(
            "SELECT * FROM note WHERE id = ?;", [.uuid(id)]
        ) else { return nil }
        return try Note(row: row)
    }

    /// FTS5 araması. Boş/yalnız noktalama sorgusunda tüm notları döndürür.
    ///
    /// Sorgu, indekslenen metinle aynı Türkçe katlamasından geçer; böylece
    /// "calisma" yazınca "Çalışma" bulunur.
    public func search(_ text: String) async throws -> [Note] {
        guard let match = Self.ftsQuery(from: TurkishText.fold(text)) else {
            return try await all()
        }
        let rows = try await database.query(
            """
            SELECT n.* FROM note_fts f
            JOIN note n ON n.id = f.note_id
            WHERE note_fts MATCH ?
            ORDER BY rank;
            """,
            [.text(match)]
        )
        return try rows.map(Note.init(row:))
    }

    // MARK: - Yazma

    @discardableResult
    public func create(
        title: String = "",
        body: String = "",
        projectID: UUID? = nil,
        folder: String = ""
    ) async throws -> Note {
        let note = Note(title: title, body: body, projectID: projectID, folder: folder)
        try await database.run(
            """
            INSERT INTO note (id, title, body, search_text, project_id, folder, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .uuid(note.id), .text(note.title), .text(note.body),
                .text(TurkishText.searchText(note.title, note.body)),
                .uuidOrNull(note.projectID), .text(note.folder),
                .date(note.createdAt), .date(note.updatedAt),
            ]
        )
        return note
    }

    public func update(_ note: Note) async throws {
        var updated = note
        updated.updatedAt = Date()
        try await database.run(
            """
            UPDATE note
            SET title = ?, body = ?, search_text = ?, project_id = ?, folder = ?, updated_at = ?
            WHERE id = ?;
            """,
            [
                .text(updated.title), .text(updated.body),
                .text(TurkishText.searchText(updated.title, updated.body)),
                .uuidOrNull(updated.projectID), .text(updated.folder),
                .date(updated.updatedAt), .uuid(updated.id),
            ]
        )
    }

    public func delete(_ id: UUID) async throws {
        try await database.run("DELETE FROM note WHERE id = ?;", [.uuid(id)])
    }

    // MARK: - FTS sorgu temizliği

    /// Hafıza araması da aynı kuralı kullanıyor; ortak hâli `FTS.query`.
    static func ftsQuery(from input: String) -> String? {
        FTS.query(from: input)
    }
}
