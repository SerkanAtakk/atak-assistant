import Foundation

/// Görev listesi filtreleri.
public enum TaskFilter: Sendable, Equatable {
    case all
    case open
    case today          // açık + bugün bitiyor veya gecikmiş
    case tomorrow       // yalnız yarına düşenler
    case upcoming(days: Int)
    case overdue
    case completed
    case project(UUID)
    case subtasks(of: UUID)
    case search(String)
}

public struct TaskService: Sendable {

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Okuma

    public func list(_ filter: TaskFilter = .open) async throws -> [TaskItem] {
        let (whereClause, parameters) = Self.clause(for: filter)

        let rows = try await database.query(
            """
            SELECT * FROM task
            WHERE \(whereClause)
            ORDER BY
                CASE status WHEN 'done' THEN 1 WHEN 'cancelled' THEN 1 ELSE 0 END,
                (due_at IS NULL),
                due_at ASC,
                priority DESC,
                sort_order ASC,
                created_at ASC;
            """,
            parameters
        )

        var tasks = try rows.map(TaskItem.init(row:))
        try await attachTags(to: &tasks)
        return tasks
    }

    public func find(_ id: UUID) async throws -> TaskItem? {
        guard let row = try await database.queryOne(
            "SELECT * FROM task WHERE id = ?;", [.uuid(id)]
        ) else { return nil }
        var task = try TaskItem(row: row)
        task.tags = try await tags(for: task.id)
        return task
    }

    /// Dashboard için: en acil açık görevler (MIMARI §14).
    public func topPriorities(limit: Int = 3) async throws -> [TaskItem] {
        let open = try await list(.open)
        return Array(
            open.sorted { $0.urgencyScore > $1.urgencyScore }.prefix(limit)
        )
    }

    public func counts() async throws -> (open: Int, dueToday: Int, overdue: Int) {
        let bounds = Self.todayBounds()
        let rows = try await database.query(
            """
            SELECT
                SUM(CASE WHEN status IN ('todo','inProgress','blocked') THEN 1 ELSE 0 END) AS open_count,
                SUM(CASE WHEN status IN ('todo','inProgress','blocked')
                         AND due_at >= ? AND due_at < ? THEN 1 ELSE 0 END) AS today_count,
                SUM(CASE WHEN status IN ('todo','inProgress','blocked')
                         AND due_at < ? THEN 1 ELSE 0 END) AS overdue_count
            FROM task;
            """,
            [.date(bounds.start), .date(bounds.end), .date(Date())]
        )
        guard let row = rows.first else { return (0, 0, 0) }
        return (row.intValue("open_count"), row.intValue("today_count"), row.intValue("overdue_count"))
    }

    // MARK: - Yazma

    @discardableResult
    public func create(
        title: String,
        notes: String = "",
        projectID: UUID? = nil,
        parentTaskID: UUID? = nil,
        priority: TaskPriority = .normal,
        dueAt: Date? = nil,
        estimatedMinutes: Int? = nil,
        tags: [String] = []
    ) async throws -> TaskItem {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ATAKError.validation("Görev başlığı boş olamaz.")
        }

        let task = TaskItem(
            projectID: projectID,
            parentTaskID: parentTaskID,
            title: trimmed,
            notes: notes,
            priority: priority,
            dueAt: dueAt,
            estimatedMinutes: estimatedMinutes,
            sortOrder: Date().timeIntervalSince1970,
            tags: tags
        )

        var statements: [SQLStatement] = [
            SQLStatement(
                """
                INSERT INTO task
                    (id, project_id, parent_task_id, title, notes, status, priority,
                     start_at, due_at, estimated_minutes, actual_minutes, completed_at,
                     created_at, updated_at, sort_order)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?);
                """,
                [
                    .uuid(task.id), .uuidOrNull(task.projectID), .uuidOrNull(task.parentTaskID),
                    .text(task.title), .text(task.notes), .text(task.status.rawValue),
                    .int(task.priority.rawValue), .dateOrNull(task.startAt), .dateOrNull(task.dueAt),
                    .intOrNull(task.estimatedMinutes),
                    .date(task.createdAt), .date(task.updatedAt), .real(task.sortOrder),
                ]
            )
        ]
        statements.append(contentsOf: Self.tagStatements(taskID: task.id, tags: tags, includeDelete: false))

        try await database.transaction(statements)
        return task
    }

    public func update(_ task: TaskItem) async throws {
        let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ATAKError.validation("Görev başlığı boş olamaz.")
        }

        var statements: [SQLStatement] = [
            SQLStatement(
                """
                UPDATE task
                SET project_id = ?, parent_task_id = ?, title = ?, notes = ?, status = ?,
                    priority = ?, start_at = ?, due_at = ?, estimated_minutes = ?,
                    actual_minutes = ?, completed_at = ?, updated_at = ?, sort_order = ?
                WHERE id = ?;
                """,
                [
                    .uuidOrNull(task.projectID), .uuidOrNull(task.parentTaskID),
                    .text(trimmed), .text(task.notes), .text(task.status.rawValue),
                    .int(task.priority.rawValue), .dateOrNull(task.startAt), .dateOrNull(task.dueAt),
                    .intOrNull(task.estimatedMinutes), .intOrNull(task.actualMinutes),
                    .dateOrNull(task.completedAt), .date(Date()), .real(task.sortOrder),
                    .uuid(task.id),
                ]
            )
        ]
        statements.append(contentsOf: Self.tagStatements(taskID: task.id, tags: task.tags, includeDelete: true))

        try await database.transaction(statements)
    }

    /// Tamamlandı/geri al. `completed_at` tutarlı kalsın diye tek yerden yönetilir.
    public func setCompleted(_ id: UUID, _ completed: Bool) async throws {
        try await database.run(
            """
            UPDATE task
            SET status = ?, completed_at = ?, updated_at = ?
            WHERE id = ?;
            """,
            [
                .text(completed ? TaskStatus.done.rawValue : TaskStatus.todo.rawValue),
                completed ? .date(Date()) : .null,
                .date(Date()),
                .uuid(id),
            ]
        )
    }

    public func setStatus(_ id: UUID, _ status: TaskStatus) async throws {
        try await database.run(
            "UPDATE task SET status = ?, completed_at = ?, updated_at = ? WHERE id = ?;",
            [
                .text(status.rawValue),
                status == .done ? .date(Date()) : .null,
                .date(Date()),
                .uuid(id),
            ]
        )
    }

    /// Görevi siler. Alt görevler `ON DELETE CASCADE` ile birlikte gider.
    public func delete(_ id: UUID) async throws {
        try await database.run("DELETE FROM task WHERE id = ?;", [.uuid(id)])
    }

    // MARK: - Etiketler

    public func tags(for taskID: UUID) async throws -> [String] {
        let rows = try await database.query(
            "SELECT tag FROM task_tag WHERE task_id = ? ORDER BY tag;", [.uuid(taskID)]
        )
        return rows.compactMap { $0.string("tag") }
    }

    public func allTags() async throws -> [String] {
        let rows = try await database.query(
            "SELECT DISTINCT tag FROM task_tag ORDER BY tag;"
        )
        return rows.compactMap { $0.string("tag") }
    }

    // MARK: - Yardımcılar

    private func attachTags(to tasks: inout [TaskItem]) async throws {
        guard !tasks.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: tasks.count).joined(separator: ",")
        let rows = try await database.query(
            "SELECT task_id, tag FROM task_tag WHERE task_id IN (\(placeholders));",
            tasks.map { .uuid($0.id) }
        )

        var byTask: [UUID: [String]] = [:]
        for row in rows {
            guard let id = row.uuid("task_id"), let tag = row.string("tag") else { continue }
            byTask[id, default: []].append(tag)
        }
        for index in tasks.indices {
            tasks[index].tags = (byTask[tasks[index].id] ?? []).sorted()
        }
    }

    private static func tagStatements(taskID: UUID, tags: [String], includeDelete: Bool) -> [SQLStatement] {
        var statements: [SQLStatement] = []
        if includeDelete {
            statements.append(SQLStatement("DELETE FROM task_tag WHERE task_id = ?;", [.uuid(taskID)]))
        }
        let cleaned = Set(
            tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
        for tag in cleaned.sorted() {
            statements.append(SQLStatement(
                "INSERT OR IGNORE INTO task_tag (task_id, tag) VALUES (?, ?);",
                [.uuid(taskID), .text(tag)]
            ))
        }
        return statements
    }

    static func todayBounds() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    private static func clause(for filter: TaskFilter) -> (String, [SQLValue]) {
        let openStatuses = "status IN ('todo','inProgress','blocked')"

        switch filter {
        case .all:
            return ("1 = 1", [])

        case .open:
            return (openStatuses, [])

        case .today:
            let bounds = todayBounds()
            return ("\(openStatuses) AND due_at IS NOT NULL AND due_at < ?", [.date(bounds.end)])

        case .tomorrow:
            // Yalnız yarının penceresi: bugüne veya öbür güne taşmaz.
            let bounds = todayBounds()
            let end = Calendar.current.date(byAdding: .day, value: 2, to: bounds.start)
                ?? bounds.start.addingTimeInterval(2 * 86_400)
            return (
                "\(openStatuses) AND due_at >= ? AND due_at < ?",
                [.date(bounds.end), .date(end)]
            )

        case .upcoming(let days):
            let bounds = todayBounds()
            let end = Calendar.current.date(byAdding: .day, value: days, to: bounds.start)
                ?? bounds.start.addingTimeInterval(Double(days) * 86_400)
            return ("\(openStatuses) AND due_at IS NOT NULL AND due_at < ?", [.date(end)])

        case .overdue:
            return ("\(openStatuses) AND due_at IS NOT NULL AND due_at < ?", [.date(Date())])

        case .completed:
            return ("status = 'done'", [])

        case .project(let id):
            return ("project_id = ?", [.uuid(id)])

        case .subtasks(let parentID):
            return ("parent_task_id = ?", [.uuid(parentID)])

        case .search(let text):
            let pattern = "%\(text.trimmingCharacters(in: .whitespacesAndNewlines))%"
            return ("(title LIKE ? OR notes LIKE ?)", [.text(pattern), .text(pattern)])
        }
    }
}
