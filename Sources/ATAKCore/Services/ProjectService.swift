import Foundation

public struct ProjectService: Sendable {

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func all(includeArchived: Bool = false) async throws -> [Project] {
        let sql = includeArchived
            ? "SELECT * FROM project ORDER BY created_at DESC;"
            : "SELECT * FROM project WHERE archived = 0 ORDER BY created_at DESC;"
        let rows = try await database.query(sql)
        return try rows.map(Project.init(row:))
    }

    public func find(_ id: UUID) async throws -> Project? {
        guard let row = try await database.queryOne(
            "SELECT * FROM project WHERE id = ?;", [.uuid(id)]
        ) else { return nil }
        return try Project(row: row)
    }

    @discardableResult
    public func create(
        name: String,
        details: String = "",
        color: ProjectColor = .blue,
        deadline: Date? = nil
    ) async throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ATAKError.validation("Proje adı boş olamaz.")
        }

        let project = Project(name: trimmed, details: details, color: color, deadline: deadline)
        try await database.run(
            """
            INSERT INTO project (id, name, description, status, color, deadline, created_at, archived)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0);
            """,
            [
                .uuid(project.id), .text(project.name), .text(project.details),
                .text(project.status.rawValue), .text(project.color.rawValue),
                .dateOrNull(project.deadline), .date(project.createdAt),
            ]
        )
        return project
    }

    public func update(_ project: Project) async throws {
        let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ATAKError.validation("Proje adı boş olamaz.")
        }
        try await database.run(
            """
            UPDATE project
            SET name = ?, description = ?, status = ?, color = ?, deadline = ?, archived = ?
            WHERE id = ?;
            """,
            [
                .text(trimmed), .text(project.details), .text(project.status.rawValue),
                .text(project.color.rawValue), .dateOrNull(project.deadline),
                .bool(project.archived), .uuid(project.id),
            ]
        )
    }

    /// Projeyi siler. Görevler `ON DELETE SET NULL` ile korunur —
    /// kullanıcının işi proje silindi diye kaybolmaz.
    public func delete(_ id: UUID) async throws {
        try await database.run("DELETE FROM project WHERE id = ?;", [.uuid(id)])
    }

    /// Tüm projeler için görev sayımlarını tek sorguda çıkarır.
    public func progressByProject() async throws -> [UUID: ProjectProgress] {
        let rows = try await database.query(
            """
            SELECT project_id,
                   COUNT(*) AS total,
                   SUM(CASE WHEN status = 'done' THEN 1 ELSE 0 END) AS done
            FROM task
            WHERE project_id IS NOT NULL
            GROUP BY project_id;
            """
        )

        var result: [UUID: ProjectProgress] = [:]
        for row in rows {
            guard let id = row.uuid("project_id") else { continue }
            result[id] = ProjectProgress(
                total: row.intValue("total"),
                done: row.intValue("done")
            )
        }
        return result
    }
}
