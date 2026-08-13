import Foundation

public struct ToolExecutionResult: Sendable {
    /// Modele geri dönen metin.
    public let content: String
    /// Kullanıcıya rozet olarak gösterilen kısa özet.
    public let summary: String
    public let isError: Bool
}

/// Bir aracın iç sonucu: modele dönen metin, rozet özeti ve — varsa — bu işi
/// geri almak için gereken bilgi.
struct ToolOutcome {
    var content: String
    var summary: String
    var undo: UndoToken?
    /// Kaydın gerçekten yazıldığı doğrulandı mı (MIMARI §32)?
    var verified: Bool = true

    init(content: String, summary: String, undo: UndoToken? = nil, verified: Bool = true) {
        self.content = content
        self.summary = summary
        self.undo = undo
        self.verified = verified
    }
}

/// Odak zamanlayıcısını araç katmanına açan en dar arayüz.
///
/// `FocusTimer` `@MainActor`; araç kutusu arka planda çalışan bir `struct`.
/// Tüm sınıfı taşımak yerine yalnız bu tek yetenek geçiriliyor.
public protocol FocusTimerControlling: Sendable {
    func startTimer(minutes: Int, note: String) async
}

/// ATAK'ın araç kataloğu ve yürütücüsü (MIMARI §5).
///
/// Her çağrı aynı hattan geçer:
/// şema → risk → (gerekirse) onay → çalıştır → doğrula → denetim kaydı.
/// Araçların kendisi bu hattı bilmez; güvenlik kararları tek yerde durur.
public struct ATAKToolbox: Sendable {

    private let tasks: TaskService
    private let notes: NoteService
    private let projects: ProjectService
    private let memory: MemoryService?
    private let calendar: CalendarService?
    private let timer: FocusTimerControlling?
    private let actionLog: ActionLogService?
    private let consent: ConsentRequesting

    public init(
        tasks: TaskService,
        notes: NoteService,
        projects: ProjectService,
        memory: MemoryService? = nil,
        calendar: CalendarService? = nil,
        timer: FocusTimerControlling? = nil,
        actionLog: ActionLogService? = nil,
        // Varsayılan **reddetmek**: onay kapısı bağlanmamış bir yapılandırmada
        // riskli araç sessizce çalışmaktansa hiç çalışmasın.
        consent: ConsentRequesting = FixedConsent(.denied)
    ) {
        self.tasks = tasks
        self.notes = notes
        self.projects = projects
        self.memory = memory
        self.calendar = calendar
        self.timer = timer
        self.actionLog = actionLog
        self.consent = consent
    }

    // MARK: - Güvenlik künyeleri

    /// Her aracın risk künyesi tek tabloda (MIMARI §5).
    ///
    /// Kataloğa yeni araç eklenip buraya künye eklenmezse `nil` döner ve araç
    /// çalıştırılmaz: bilinmeyen bir aracın varsayılan olarak "düşük riskli"
    /// sayılması, tam da kaçınılması gereken hata.
    static func safety(for name: String) -> ToolSafety? {
        switch name {
        case "create_task":
            return ToolSafety(risk: .medium, friendlyName: "görev oluşturma")
        case "list_tasks":
            return ToolSafety(risk: .low, friendlyName: "görevleri okuma")
        case "complete_task":
            return ToolSafety(risk: .medium, friendlyName: "görev tamamlama")
        case "create_note":
            return ToolSafety(risk: .medium, friendlyName: "not kaydetme")
        case "search_notes":
            return ToolSafety(risk: .low, friendlyName: "notlarda arama")
        case "create_project":
            return ToolSafety(risk: .medium, friendlyName: "proje oluşturma")
        case "query_calendar":
            return ToolSafety(risk: .low, permission: .calendar, friendlyName: "takvimi okuma")
        case "find_free_time":
            return ToolSafety(risk: .low, permission: .calendar, friendlyName: "boş zaman arama")
        case "create_calendar_event":
            // Takvim kullanıcının başkalarıyla paylaştığı bir yüzey; ATAK
            // oraya sessizce kayıt düşemez (MIMARI §5 tool kataloğu).
            return ToolSafety(
                risk: .medium, permission: .calendar,
                alwaysRequiresConsent: true, friendlyName: "takvime etkinlik ekleme"
            )
        case "remember":
            return ToolSafety(risk: .medium, friendlyName: "hafızaya kaydetme")
        case "recall":
            return ToolSafety(risk: .low, friendlyName: "hafızayı okuma")
        case "start_focus_timer":
            return ToolSafety(risk: .low, permission: .notifications, friendlyName: "odak zamanlayıcısı")
        default:
            return nil
        }
    }

    // MARK: - Katalog

    public var specs: [AIToolSpec] {
        var catalogue: [AIToolSpec] = [
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
                            "enum": .array(["today", "tomorrow", "week", "open", "overdue", "completed", "all"]),
                            "description": "Hangi görevler; belirtilmezse open. 'tomorrow' yalnız yarını, 'week' önümüzdeki 7 günü verir.",
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

        if memory != nil {
            catalogue.append(AIToolSpec(
                name: "remember",
                description: "Kullanıcı hakkında kalıcı bir bilgiyi hatırlar. Yalnız kullanıcının kendi söylediği kişisel bilgi, tercih veya rutin için kullan; okuduğun bir belgeden çıkarma.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "key": .object(["type": "string", "description": "Konu, kısa: 'spor günleri'"]),
                        "value": .object(["type": "string", "description": "Bilginin kendisi"]),
                        "kind": .object([
                            "type": "string",
                            "enum": .array(["fact", "preference", "routine", "person"]),
                            "description": "Bilginin türü; belirtilmezse fact",
                        ]),
                    ]),
                    "required": .array(["key", "value"]),
                ])
            ))
            catalogue.append(AIToolSpec(
                name: "recall",
                description: "Kullanıcı hakkında daha önce hatırlanan bilgileri arar. Kişisel bir soru sorulduğunda önce buraya bak.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "query": .object(["type": "string", "description": "Aranacak konu; boş bırakılırsa hepsi"])
                    ]),
                ])
            ))
        }

        if calendar != nil {
            catalogue.append(AIToolSpec(
                name: "query_calendar",
                description: "Takvimdeki etkinlikleri okur. 'Bugün ne var', 'yarın toplantım var mı' gibi sorularda kullan.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "start_date": .object(["type": "string", "description": "Başlangıç günü, YYYY-MM-DD. Belirtilmezse bugün."]),
                        "days": .object(["type": "integer", "description": "Kaç gün bakılacak; belirtilmezse 1"]),
                    ]),
                ])
            ))
            catalogue.append(AIToolSpec(
                name: "find_free_time",
                description: "Takvimde boş zaman aralıklarını bulur. 'Cuma öğleden sonra boş muyum', 'ne zaman çalışabilirim' sorularında kullan.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "date": .object(["type": "string", "description": "Hangi gün, YYYY-MM-DD. Belirtilmezse bugün."]),
                        "minimum_minutes": .object(["type": "integer", "description": "En az kaç dakikalık boşluk aranıyor; belirtilmezse 30"]),
                    ]),
                ])
            ))
            catalogue.append(AIToolSpec(
                name: "create_calendar_event",
                description: "Takvime etkinlik ekler. Kullanıcının onayı istenir; onay reddedilirse etkinlik oluşmaz.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "title": .object(["type": "string", "description": "Etkinlik başlığı"]),
                        "date": .object(["type": "string", "description": "Gün, YYYY-MM-DD"]),
                        "time": .object(["type": "string", "description": "Başlangıç saati, HH:mm"]),
                        "duration_minutes": .object(["type": "integer", "description": "Süre; belirtilmezse 60"]),
                        "reason": .object(["type": "string", "description": "Bunu neden ekliyorsun — onay kartında kullanıcıya gösterilir"]),
                    ]),
                    "required": .array(["title", "date", "time"]),
                ])
            ))
        }

        if timer != nil {
            catalogue.append(AIToolSpec(
                name: "start_focus_timer",
                description: "Odak zamanlayıcısı başlatır. Kullanıcı 'çalışmaya başlıyorum', 'pomodoro' dediğinde kullan.",
                parameters: .object([
                    "type": "object",
                    "properties": .object([
                        "minutes": .object(["type": "integer", "description": "Süre; belirtilmezse 25"]),
                        "note": .object(["type": "string", "description": "Ne üzerine çalışılıyor"]),
                    ]),
                ])
            ))
        }

        return catalogue
    }

    // MARK: - Yürütme hattı

    public func execute(_ call: AIToolCall, conversationID: UUID? = nil) async -> ToolExecutionResult {
        let startedAt = Date()

        guard let safety = Self.safety(for: call.name) else {
            return ToolExecutionResult(
                content: "Bilinmeyen araç: \(call.name)",
                summary: "bilinmeyen araç",
                isError: true
            )
        }

        let assessment = RiskEngine.assess(safety, context: Self.riskContext(for: call))

        // Onay gerekiyorsa kullanıcı karar verene kadar burada beklenir.
        var consentGrantedAt: Date?
        if assessment.requiresConsent {
            let decision = await consent.requestConsent(ConsentRequest(
                title: Self.consentTitle(for: call, safety: safety),
                rationale: call.arguments["reason"]?.stringValue
                    ?? "ATAK bu işlemi isteğini tamamlamak için yapmak istiyor.",
                assessment: assessment
            ))

            guard decision.isApproved else {
                await log(
                    call: call, conversationID: conversationID, assessment: assessment,
                    status: decision == .cancelled ? .cancelled : .denied,
                    outcome: nil, error: nil, startedAt: startedAt, consentGrantedAt: nil
                )
                let message = decision == .cancelled
                    ? "İşlem iptal edildi."
                    : "Kullanıcı bu işlemi onaylamadı. Yapma ve nedenini sorma; başka bir şey öner."
                return ToolExecutionResult(content: message, summary: "onaylanmadı", isError: true)
            }
            consentGrantedAt = Date()
        }

        do {
            let outcome = try await run(call)
            await log(
                call: call, conversationID: conversationID, assessment: assessment,
                status: .succeeded, outcome: outcome, error: nil,
                startedAt: startedAt, consentGrantedAt: consentGrantedAt
            )
            return ToolExecutionResult(content: outcome.content, summary: outcome.summary, isError: false)
        } catch {
            Log.tools.error("Araç hatası \(call.name, privacy: .public): \(error.localizedDescription)")
            await log(
                call: call, conversationID: conversationID, assessment: assessment,
                status: .failed, outcome: nil, error: error.localizedDescription,
                startedAt: startedAt, consentGrantedAt: consentGrantedAt
            )
            return ToolExecutionResult(
                content: "Hata: \(error.localizedDescription)",
                summary: "başarısız",
                isError: true
            )
        }
    }

    private func run(_ call: AIToolCall) async throws -> ToolOutcome {
        switch call.name {
        case "create_task":           return try await createTask(call.arguments)
        case "list_tasks":            return try await listTasks(call.arguments)
        case "complete_task":         return try await completeTask(call.arguments)
        case "create_note":           return try await createNote(call.arguments)
        case "search_notes":          return try await searchNotes(call.arguments)
        case "create_project":        return try await createProject(call.arguments)
        case "remember":              return try await remember(call.arguments)
        case "recall":                return try await recall(call.arguments)
        case "query_calendar":        return try await queryCalendar(call.arguments)
        case "find_free_time":        return try await findFreeTime(call.arguments)
        case "create_calendar_event": return try await createCalendarEvent(call.arguments)
        case "start_focus_timer":     return try await startFocusTimer(call.arguments)
        default:
            throw ATAKError.unsupported("Bilinmeyen araç: \(call.name)")
        }
    }

    /// Denetim kaydı — başarılı da başarısız da yazılır.
    ///
    /// Kayıt yazılamazsa aracın sonucu değişmez: defter tutulamıyor diye
    /// kullanıcının işini bozmak yanlış olur, ama sessizce geçmek de yanlış.
    private func log(
        call: AIToolCall,
        conversationID: UUID?,
        assessment: RiskAssessment,
        status: ActionStatus,
        outcome: ToolOutcome?,
        error: String?,
        startedAt: Date,
        consentGrantedAt: Date?
    ) async {
        guard let actionLog else { return }

        let input = (try? JSONEncoder().encode(call.arguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        do {
            try await actionLog.record(AssistantAction(
                conversationID: conversationID,
                toolID: call.name,
                input: input,
                summary: outcome?.summary ?? "",
                undo: outcome?.undo,
                risk: assessment.level,
                requiredConsent: assessment.requiresConsent,
                consentGrantedAt: consentGrantedAt,
                status: status,
                verified: outcome?.verified ?? false,
                error: error,
                startedAt: startedAt
            ))
        } catch {
            Log.tools.error("Denetim kaydı yazılamadı: \(error.localizedDescription)")
        }
    }

    /// Çağrının bağlamsal risk girdileri (MIMARI §8).
    static func riskContext(for call: AIToolCall) -> RiskContext {
        RiskContext(
            affectedCount: 1,
            leavesDevice: false,
            // v0.3'te ATAK henüz dış içerik okumuyor; okuma araçları
            // eklendiğinde bu bayrak oradan gelecek.
            derivedFromUntrustedContent: false
        )
    }

    static func consentTitle(for call: AIToolCall, safety: ToolSafety) -> String {
        switch call.name {
        case "create_calendar_event":
            let title = call.arguments["title"]?.stringValue ?? "etkinlik"
            let date = call.arguments["date"]?.stringValue ?? ""
            let time = call.arguments["time"]?.stringValue ?? ""
            return "Takvime \"\(title)\" ekle — \(date) \(time)".trimmingCharacters(in: .whitespaces)
        default:
            return safety.friendlyName.prefix(1).uppercased() + safety.friendlyName.dropFirst()
        }
    }

    // MARK: - Görevler

    private func createTask(_ arguments: JSONValue) async throws -> ToolOutcome {
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

        // Kimlik `complete_task` için gerekli ama kullanıcıya gösterilecek bir
        // şey değil; modelin yanıtına kopyalamaması için açıkça işaretleniyor.
        var detail = "Görev oluşturuldu: \"\(saved.title)\"\n[dahili_kimlik=\(saved.id.uuidString) — kullanıcıya yazma]"
        if let dueAt = saved.dueAt { detail += ", son tarih \(DateFormat.full(dueAt))" }

        return ToolOutcome(
            content: detail,
            summary: "görev: \(saved.title)",
            undo: UndoToken(kind: .taskCreated, targetID: saved.id.uuidString, label: saved.title)
        )
    }

    private func listTasks(_ arguments: JSONValue) async throws -> ToolOutcome {
        let filter: TaskFilter
        switch arguments["filter"]?.stringValue {
        case "today":     filter = .today
        case "tomorrow":  filter = .tomorrow
        case "week":      filter = .upcoming(days: 7)
        case "overdue":   filter = .overdue
        case "completed": filter = .completed
        case "all":       filter = .all
        default:          filter = .open
        }

        let items = try await tasks.list(filter)
        guard !items.isEmpty else {
            return ToolOutcome(content: "Bu filtrede görev yok.", summary: "0 görev")
        }

        let lines = items.prefix(40).map { task -> String in
            var line = "- [\(task.status.rawValue)] \(task.title) [dahili_kimlik=\(task.id.uuidString)]"
            if let due = task.dueAt { line += " · son tarih: \(DateFormat.full(due))" }
            if task.priority != .normal { line += " · öncelik: \(task.priority.displayName)" }
            if let minutes = task.estimatedMinutes { line += " · tahmini: \(minutes) dk" }
            return line
        }

        return ToolOutcome(
            content: lines.joined(separator: "\n"),
            summary: "\(items.count) görev okundu"
        )
    }

    private func completeTask(_ arguments: JSONValue) async throws -> ToolOutcome {
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

        return ToolOutcome(
            content: "\"\(task.title)\" tamamlandı olarak işaretlendi.",
            summary: "tamamlandı: \(task.title)",
            undo: UndoToken(kind: .taskCompleted, targetID: id.uuidString, label: task.title)
        )
    }

    // MARK: - Notlar ve projeler

    private func createNote(_ arguments: JSONValue) async throws -> ToolOutcome {
        guard let body = arguments["body"]?.stringValue, !body.isEmpty else {
            throw ATAKError.validation("Not içeriği gerekli.")
        }
        let note = try await notes.create(
            title: arguments["title"]?.stringValue ?? "",
            body: body
        )

        guard let persisted = try await notes.find(note.id) else {
            throw ATAKError.database("Not oluşturulduktan sonra doğrulanamadı.")
        }
        return ToolOutcome(
            content: "Not kaydedildi: \"\(persisted.displayTitle)\"",
            summary: "not: \(persisted.displayTitle)",
            undo: UndoToken(kind: .noteCreated, targetID: persisted.id.uuidString, label: persisted.displayTitle)
        )
    }

    private func searchNotes(_ arguments: JSONValue) async throws -> ToolOutcome {
        guard let query = arguments["query"]?.stringValue else {
            throw ATAKError.validation("Arama kelimesi gerekli.")
        }
        let results = try await notes.search(query)
        guard !results.isEmpty else {
            return ToolOutcome(content: "\"\(query)\" için not bulunamadı.", summary: "sonuç yok")
        }
        let lines = results.prefix(10).map { "- \($0.displayTitle): \($0.preview.prefix(200))" }
        return ToolOutcome(
            content: lines.joined(separator: "\n"),
            summary: "\(results.count) not bulundu"
        )
    }

    private func createProject(_ arguments: JSONValue) async throws -> ToolOutcome {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            throw ATAKError.validation("Proje adı gerekli.")
        }
        let project = try await projects.create(
            name: name,
            details: arguments["description"]?.stringValue ?? ""
        )

        guard let persisted = try await projects.find(project.id) else {
            throw ATAKError.database("Proje oluşturulduktan sonra doğrulanamadı.")
        }
        return ToolOutcome(
            content: "Proje oluşturuldu: \"\(persisted.name)\"\n[dahili_kimlik=\(persisted.id.uuidString) — kullanıcıya yazma]",
            summary: "proje: \(persisted.name)",
            undo: UndoToken(kind: .projectCreated, targetID: persisted.id.uuidString, label: persisted.name)
        )
    }

    // MARK: - Hafıza

    private func remember(_ arguments: JSONValue) async throws -> ToolOutcome {
        guard let memory else { throw ATAKError.unsupported("Hafıza kullanılamıyor.") }
        guard let key = arguments["key"]?.stringValue,
              let value = arguments["value"]?.stringValue else {
            throw ATAKError.validation("Hafıza kaydı için konu ve içerik gerekli.")
        }

        let kind = MemoryItem.Kind(rawValue: arguments["kind"]?.stringValue ?? "") ?? .fact
        let item = try await memory.remember(kind: kind, key: key, value: value, source: .userStated)

        guard try await memory.find(item.id) != nil else {
            throw ATAKError.database("Hafıza kaydı doğrulanamadı.")
        }
        return ToolOutcome(
            content: "Hatırlanıyor — \(item.key): \(item.value)",
            summary: "hatırlandı: \(item.key)",
            undo: UndoToken(kind: .memoryStored, targetID: item.id.uuidString, label: item.key)
        )
    }

    private func recall(_ arguments: JSONValue) async throws -> ToolOutcome {
        guard let memory else { throw ATAKError.unsupported("Hafıza kullanılamıyor.") }

        let query = arguments["query"]?.stringValue ?? ""
        let items = query.isEmpty ? try await memory.all() : try await memory.search(query)

        guard !items.isEmpty else {
            return ToolOutcome(content: "Bu konuda hatırlanan bir şey yok.", summary: "kayıt yok")
        }
        let lines = items.prefix(15).map { "- \($0.key): \($0.value)" }
        return ToolOutcome(
            content: lines.joined(separator: "\n"),
            summary: "\(items.count) hatırlama"
        )
    }

    // MARK: - Takvim

    private func queryCalendar(_ arguments: JSONValue) async throws -> ToolOutcome {
        guard let calendar else { throw ATAKError.unsupported("Takvim kullanılamıyor.") }

        let start = Self.parseDay(arguments["start_date"]?.stringValue)
            ?? TaskService.todayBounds().start
        let days = max(1, min(arguments["days"]?.intValue ?? 1, 31))
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)
            ?? start.addingTimeInterval(Double(days) * 86_400)

        let events = try await calendar.events(from: start, to: end)
        guard !events.isEmpty else {
            return ToolOutcome(content: "Bu aralıkta takvimde etkinlik yok.", summary: "0 etkinlik")
        }

        let lines = events.prefix(40).map { "- \(DateFormat.dayAndMonth($0.startsAt)) \($0.summaryLine)" }
        return ToolOutcome(
            content: lines.joined(separator: "\n"),
            summary: "\(events.count) etkinlik"
        )
    }

    private func findFreeTime(_ arguments: JSONValue) async throws -> ToolOutcome {
        guard let calendar else { throw ATAKError.unsupported("Takvim kullanılamıyor.") }

        let day = Self.parseDay(arguments["date"]?.stringValue) ?? TaskService.todayBounds().start
        let minimum = max(5, arguments["minimum_minutes"]?.intValue ?? 30)

        // Gün boyu değil, makul çalışma saatleri: 09:00–22:00.
        let calendarSystem = Calendar.current
        let start = calendarSystem.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        let end = calendarSystem.date(bySettingHour: 22, minute: 0, second: 0, of: day) ?? day

        let slots = try await calendar.freeSlots(from: start, to: end, minimumMinutes: minimum)
        guard !slots.isEmpty else {
            return ToolOutcome(
                content: "\(DateFormat.dayAndMonth(day)) günü \(minimum) dakikadan uzun boşluk yok.",
                summary: "boşluk yok"
            )
        }

        let lines = slots.map { "- \(DateFormat.time($0.start))–\(DateFormat.time($0.end))" }
        return ToolOutcome(
            content: "\(DateFormat.dayAndMonth(day)) boş aralıklar:\n" + lines.joined(separator: "\n"),
            summary: "\(slots.count) boşluk"
        )
    }

    private func createCalendarEvent(_ arguments: JSONValue) async throws -> ToolOutcome {
        guard let calendar else { throw ATAKError.unsupported("Takvim kullanılamıyor.") }
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            throw ATAKError.validation("Etkinlik başlığı gerekli.")
        }
        guard let start = Self.parseDate(
            date: arguments["date"]?.stringValue,
            time: arguments["time"]?.stringValue
        ) else {
            throw ATAKError.validation("Etkinlik için geçerli bir tarih ve saat gerekli.")
        }

        let minutes = max(5, arguments["duration_minutes"]?.intValue ?? 60)
        let end = start.addingTimeInterval(Double(minutes) * 60)

        let event = try await calendar.createEvent(
            title: title, startsAt: start, endsAt: end
        )

        return ToolOutcome(
            content: "Takvime eklendi: \(event.summaryLine) (\(DateFormat.dayAndMonth(event.startsAt)))",
            summary: "takvim: \(event.title)",
            undo: UndoToken(kind: .calendarEventCreated, targetID: event.id, label: event.title)
        )
    }

    // MARK: - Odak

    private func startFocusTimer(_ arguments: JSONValue) async throws -> ToolOutcome {
        guard let timer else { throw ATAKError.unsupported("Zamanlayıcı kullanılamıyor.") }

        let minutes = min(max(arguments["minutes"]?.intValue ?? 25, 1), 180)
        let note = arguments["note"]?.stringValue ?? ""
        await timer.startTimer(minutes: minutes, note: note)

        return ToolOutcome(
            content: "\(minutes) dakikalık odak başladı\(note.isEmpty ? "" : ": \(note)").",
            summary: "odak: \(minutes) dk"
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

    /// "2026-08-14" → o günün başlangıcı (00:00).
    static func parseDay(_ date: String?) -> Date? {
        guard let parsed = parseDate(date: date, time: "00:00") else { return nil }
        return Calendar.current.startOfDay(for: parsed)
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
