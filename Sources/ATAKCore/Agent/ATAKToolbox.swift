import Foundation

public struct ToolExecutionResult: Sendable {
    /// Modele geri dönen metin.
    public let content: String
    /// Kullanıcıya rozet olarak gösterilen kısa özet.
    public let summary: String
    public let isError: Bool
}

/// ATAK'ın araç kataloğu ve yürütücüsü (MIMARI §5).
///
/// Buradaki araçların hepsi düşük/orta riskli ve geri alınabilir; bu yüzden
/// onay istemezler. Silme, e-posta ve terminal gibi yüksek riskli araçlar
/// v0.3'te `ConsentGate` arkasına eklenecek.
public struct ATAKToolbox: Sendable {

    private let tasks: TaskService
    private let notes: NoteService
    private let projects: ProjectService

    public init(tasks: TaskService, notes: NoteService, projects: ProjectService) {
        self.tasks = tasks
        self.notes = notes
        self.projects = projects
    }

    // MARK: - Katalog

    public var specs: [AIToolSpec] {
        [
            AIToolSpec(
                name: "create_task",
                description: "Kullanıcı için yeni bir görev oluşturur. Kullanıcı yapılacak bir iş, plan veya hatırlatma tarif ettiğinde kullan.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "title": .object([
                            "type": "string",
                            "description": "Görevin kısa başlığı",
                        ]),
                        "notes": .object([
                            "type": "string",
                            "description": "İsteğe bağlı ayrıntı",
                        ]),
                        "priority": .object([
                            "type": "string",
                            "enum": .array(["low", "normal", "high", "urgent"]),
                            "description": "Öncelik; belirtilmezse normal",
                        ]),
                        "due_date": .object([
                            "type": "string",
                            "description": "Son tarih, YYYY-MM-DD biçiminde. Bugünün tarihini temel al.",
                        ]),
                        "due_time": .object([
                            "type": "string",
                            "description": "Saat, HH:mm biçiminde (isteğe bağlı)",
                        ]),
                        "estimated_minutes": .object([
                            "type": "integer",
                            "description": "Tahmini süre (dakika)",
                        ]),
                    ]),
                    "required": .array(["title"]),
                ])
            ),

            AIToolSpec(
                name: "list_tasks",
                description: "Kullanıcının görevlerini listeler. Plan yapmadan veya 'bugün ne yapmalıyım' sorusuna cevap vermeden önce kullan.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "filter": .object([
                            "type": "string",
                            "enum": .array(["today", "open", "overdue", "completed", "all"]),
                            "description": "Hangi görevler; belirtilmezse open",
                        ])
                    ]),
                ])
            ),

            AIToolSpec(
                name: "complete_task",
                description: "Bir görevi tamamlandı olarak işaretler. Önce list_tasks ile görevin kimliğini öğren.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "task_id": .object([
                            "type": "string",
                            "description": "list_tasks'ten dönen görev kimliği",
                        ])
                    ]),
                    "required": .array(["task_id"]),
                ])
            ),

            AIToolSpec(
                name: "create_note",
                description: "Yeni bir not kaydeder. Kullanıcı 'bunu not al', 'kaydet' dediğinde kullan.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "title": .object(["type": "string", "description": "Not başlığı"]),
                        "body": .object(["type": "string", "description": "Notun içeriği"]),
                    ]),
                    "required": .array(["body"]),
                ])
            ),

            AIToolSpec(
                name: "search_notes",
                description: "Notlarda arama yapar. Kullanıcı daha önce kaydettiği bir şeyi sorduğunda kullan.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "query": .object(["type": "string", "description": "Aranacak kelime"])
                    ]),
                    "required": .array(["query"]),
                ])
            ),

            AIToolSpec(
                name: "create_project",
                description: "Yeni bir proje oluşturur. Kullanıcı büyük, çok adımlı bir hedeften bahsettiğinde kullan.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "name": .object(["type": "string", "description": "Proje adı"]),
                        "description": .object(["type": "string", "description": "Kısa açıklama"]),
                    ]),
                    "required": .array(["name"]),
                ])
            ),
        ]
    }

    // MARK: - Yürütme

    public func execute(_ call: AIToolCall) async -> ToolExecutionResult {
        do {
            switch call.name {
            case "create_task":     return try await createTask(call.arguments)
            case "list_tasks":      return try await listTasks(call.arguments)
            case "complete_task":   return try await completeTask(call.arguments)
            case "create_note":     return try await createNote(call.arguments)
            case "search_notes":    return try await searchNotes(call.arguments)
            case "create_project":  return try await createProject(call.arguments)
            default:
                return ToolExecutionResult(
                    content: "Bilinmeyen araç: \(call.name)",
                    summary: "bilinmeyen araç",
                    isError: true
                )
            }
        } catch {
            Log.tools.error("Araç hatası \(call.name, privacy: .public): \(error.localizedDescription)")
            return ToolExecutionResult(
                content: "Hata: \(error.localizedDescription)",
                summary: "başarısız",
                isError: true
            )
        }
    }

    private func createTask(_ arguments: JSONValue) async throws -> ToolExecutionResult {
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            throw ATAKError.validation("Görev başlığı gerekli.")
        }

        let priority = TaskPriority.named(arguments["priority"]?.stringValue)
        let due = Self.parseDate(
            date: arguments["due_date"]?.stringValue,
            time: arguments["due_time"]?.stringValue
        )

        let task = try await tasks.create(
            title: title,
            notes: arguments["notes"]?.stringValue ?? "",
            priority: priority,
            dueAt: due,
            estimatedMinutes: arguments["estimated_minutes"]?.intValue
        )

        // Doğrulama (MIMARI §32): gerçekten yazıldı mı?
        guard let saved = try await tasks.find(task.id) else {
            throw ATAKError.database("Görev kaydedildi görünüyor ama geri okunamadı.")
        }

        var detail = "Görev oluşturuldu: \"\(saved.title)\" (id: \(saved.id.uuidString))"
        if let dueAt = saved.dueAt { detail += ", son tarih \(DateFormat.full(dueAt))" }

        return ToolExecutionResult(
            content: detail,
            summary: "görev: \(saved.title)",
            isError: false
        )
    }

    private func listTasks(_ arguments: JSONValue) async throws -> ToolExecutionResult {
        let filter: TaskFilter
        switch arguments["filter"]?.stringValue {
        case "today":     filter = .today
        case "overdue":   filter = .overdue
        case "completed": filter = .completed
        case "all":       filter = .all
        default:          filter = .open
        }

        let items = try await tasks.list(filter)
        guard !items.isEmpty else {
            return ToolExecutionResult(content: "Bu filtrede görev yok.", summary: "0 görev", isError: false)
        }

        let lines = items.prefix(40).map { task -> String in
            var line = "- [\(task.status.rawValue)] \(task.title) (id: \(task.id.uuidString))"
            if let due = task.dueAt { line += " · son tarih: \(DateFormat.full(due))" }
            if task.priority != .normal { line += " · öncelik: \(task.priority.displayName)" }
            if let minutes = task.estimatedMinutes { line += " · tahmini: \(minutes) dk" }
            return line
        }

        return ToolExecutionResult(
            content: lines.joined(separator: "\n"),
            summary: "\(items.count) görev okundu",
            isError: false
        )
    }

    private func completeTask(_ arguments: JSONValue) async throws -> ToolExecutionResult {
        guard let raw = arguments["task_id"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw ATAKError.validation("Geçerli bir görev kimliği gerekli.")
        }
        guard let task = try await tasks.find(id) else {
            throw ATAKError.notFound(entity: "Görev", id: raw)
        }

        try await tasks.setCompleted(id, true)

        guard try await tasks.find(id)?.status == .done else {
            throw ATAKError.database("Görev tamamlanmış olarak kaydedilemedi.")
        }

        return ToolExecutionResult(
            content: "\"\(task.title)\" tamamlandı olarak işaretlendi.",
            summary: "tamamlandı: \(task.title)",
            isError: false
        )
    }

    private func createNote(_ arguments: JSONValue) async throws -> ToolExecutionResult {
        guard let body = arguments["body"]?.stringValue, !body.isEmpty else {
            throw ATAKError.validation("Not içeriği gerekli.")
        }
        let note = try await notes.create(
            title: arguments["title"]?.stringValue ?? "",
            body: body
        )
        return ToolExecutionResult(
            content: "Not kaydedildi: \"\(note.displayTitle)\"",
            summary: "not: \(note.displayTitle)",
            isError: false
        )
    }

    private func searchNotes(_ arguments: JSONValue) async throws -> ToolExecutionResult {
        guard let query = arguments["query"]?.stringValue else {
            throw ATAKError.validation("Arama kelimesi gerekli.")
        }
        let results = try await notes.search(query)
        guard !results.isEmpty else {
            return ToolExecutionResult(
                content: "\"\(query)\" için not bulunamadı.",
                summary: "sonuç yok",
                isError: false
            )
        }
        let lines = results.prefix(10).map { "- \($0.displayTitle): \($0.preview.prefix(200))" }
        return ToolExecutionResult(
            content: lines.joined(separator: "\n"),
            summary: "\(results.count) not bulundu",
            isError: false
        )
    }

    private func createProject(_ arguments: JSONValue) async throws -> ToolExecutionResult {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            throw ATAKError.validation("Proje adı gerekli.")
        }
        let project = try await projects.create(
            name: name,
            details: arguments["description"]?.stringValue ?? ""
        )
        return ToolExecutionResult(
            content: "Proje oluşturuldu: \"\(project.name)\" (id: \(project.id.uuidString))",
            summary: "proje: \(project.name)",
            isError: false
        )
    }

    // MARK: - Yardımcı

    /// "2026-08-14" + "18:30" → Date. Saat yoksa gün sonu (18:00) varsayılır.
    static func parseDate(date: String?, time: String?) -> Date? {
        guard let date, !date.isEmpty else { return nil }

        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }

        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]

        let timeParts = (time ?? "").split(separator: ":").compactMap { Int($0) }
        components.hour = timeParts.first ?? 18
        components.minute = timeParts.count > 1 ? timeParts[1] : 0

        return Calendar.current.date(from: components)
    }
}

extension TaskPriority {
    static func named(_ raw: String?) -> TaskPriority {
        switch raw?.lowercased() {
        case "low":    return .low
        case "high":   return .high
        case "urgent": return .urgent
        default:       return .normal
        }
    }
}
