import Testing
import Foundation
@testable import ATAKCore

// MARK: - Risk motoru

@Suite("Risk motoru")
struct RiskEngineTests {

    private let plainMedium = ToolSafety(risk: .medium, friendlyName: "test")

    @Test("Bağlam yoksa risk künyedeki seviyede kalır")
    func baselineRisk() {
        let assessment = RiskEngine.assess(plainMedium)
        #expect(assessment.level == .medium)
        #expect(!assessment.requiresConsent)
        #expect(assessment.reasons.isEmpty)
    }

    @Test("Geri alınamayan iş bir seviye yükselir ve onay ister")
    func irreversibleEscalates() {
        let safety = ToolSafety(risk: .medium, isReversible: false, friendlyName: "test")
        let assessment = RiskEngine.assess(safety)

        #expect(assessment.level == .high)
        #expect(assessment.requiresConsent)
        #expect(assessment.reasons.contains { $0.contains("Geri alınamaz") })
    }

    @Test("Eşiğin üstünde toplu işlem riski yükseltir")
    func bulkEscalates() {
        let assessment = RiskEngine.assess(
            plainMedium,
            context: RiskContext(affectedCount: RiskEngine.bulkThreshold + 1)
        )
        #expect(assessment.level == .high)
        #expect(assessment.requiresConsent)
    }

    @Test("Eşiğin altındaki sayı riski yükseltmez")
    func belowThresholdStays() {
        let assessment = RiskEngine.assess(
            plainMedium,
            context: RiskContext(affectedCount: RiskEngine.bulkThreshold)
        )
        #expect(assessment.level == .medium)
        #expect(!assessment.requiresConsent)
    }

    @Test("Veri cihazdan çıkıyorsa risk yükselir")
    func leavingDeviceEscalates() {
        let assessment = RiskEngine.assess(plainMedium, context: RiskContext(leavesDevice: true))
        #expect(assessment.level == .high)
    }

    /// Prompt injection savunmasının merkezi (MIMARI §8): okunan içerikten
    /// türeyen iş, düşük riskli olsa bile kullanıcıya sorulmalı.
    @Test("Okunan içerikten türeyen çağrı riski yükseltir")
    func untrustedContentEscalates() {
        let low = ToolSafety(risk: .low, friendlyName: "test")
        let assessment = RiskEngine.assess(
            low, context: RiskContext(derivedFromUntrustedContent: true)
        )

        #expect(assessment.level == .medium)
        #expect(assessment.reasons.contains { $0.contains("senin talimatın değil") })
    }

    @Test("Yükselmeler birikir ve yüksekte tavan yapar")
    func escalationsStack() {
        let safety = ToolSafety(risk: .medium, isReversible: false, friendlyName: "test")
        let assessment = RiskEngine.assess(
            safety,
            context: RiskContext(affectedCount: 50, leavesDevice: true, derivedFromUntrustedContent: true)
        )

        #expect(assessment.level == .high)
        #expect(assessment.reasons.count == 4)
    }

    @Test("Künyesi onay şart koşan araç düşük riskte bile sorar")
    func alwaysRequiresConsentIsHonoured() {
        let safety = ToolSafety(risk: .low, alwaysRequiresConsent: true, friendlyName: "test")
        #expect(RiskEngine.assess(safety).requiresConsent)
    }

    @Test("Katalogdaki her aracın güvenlik künyesi var")
    func everyToolHasSafety() async throws {
        let context = try await TestDatabase()
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database),
            memory: MemoryService(database: context.database)
        )

        for spec in toolbox.specs {
            #expect(ATAKToolbox.safety(for: spec.name) != nil, "künye yok: \(spec.name)")
        }
    }
}

// MARK: - Onay kapısı

@Suite("Onay kapısı")
@MainActor
struct ConsentGateTests {

    private func sampleRequest() -> ConsentRequest {
        ConsentRequest(
            title: "Test",
            rationale: "sebep",
            assessment: RiskAssessment(level: .high, requiresConsent: true, isReversible: false, reasons: [])
        )
    }

    @Test("Onay verilince istek onaylanmış döner ve kart kapanır")
    func approveResumes() async {
        let gate = ConsentGate()

        async let decision = gate.request(sampleRequest())
        // İsteğin kaydedilmesini bekle: kapı ana aktörde, bu döngü de öyle.
        while gate.pending == nil { await Task.yield() }
        gate.approve()

        #expect(await decision == .approved)
        #expect(gate.pending == nil)
    }

    @Test("Reddedilince reddedilmiş döner")
    func denyResumes() async {
        let gate = ConsentGate()

        async let decision = gate.request(sampleRequest())
        while gate.pending == nil { await Task.yield() }
        gate.deny()

        #expect(await decision == .denied)
        #expect(gate.pending == nil)
    }

    /// Askıda kalan bir devam noktası turu sonsuza kadar dondurur; iptalin
    /// beklemeyi mutlaka bitirmesi gerekir.
    @Test("İptal bekleyen isteği serbest bırakır")
    func cancelResumes() async {
        let gate = ConsentGate()

        async let decision = gate.request(sampleRequest())
        while gate.pending == nil { await Task.yield() }
        gate.cancelPending()

        #expect(await decision == .cancelled)
        #expect(gate.pending == nil)
    }

    @Test("Kapı meşgulken gelen ikinci istek reddedilir")
    func secondRequestIsDenied() async {
        let gate = ConsentGate()

        async let first = gate.request(sampleRequest())
        while gate.pending == nil { await Task.yield() }

        let second = await gate.request(sampleRequest())
        #expect(second == .denied)

        gate.approve()
        #expect(await first == .approved)
    }
}

// MARK: - Denetim defteri ve geri alma

@Suite("Denetim defteri ve geri alma")
struct ActionLogTests {

    @Test("Araç çağrısı denetim defterine yazılır")
    func toolCallIsLogged() async throws {
        let context = try await TestDatabase()
        let log = ActionLogService(database: context.database)
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database),
            actionLog: log
        )

        _ = await toolbox.execute(AIToolCall(
            id: "1", name: "create_task", arguments: .object(["title": "Denetim testi"])
        ))

        let entries = try await log.recent()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.toolID == "create_task")
        #expect(entry.status == .succeeded)
        #expect(entry.verified)
        #expect(entry.risk == .medium)
    }

    @Test("Başarısız çağrı da yazılır ve hata metni saklanır")
    func failureIsLogged() async throws {
        let context = try await TestDatabase()
        let log = ActionLogService(database: context.database)
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database),
            actionLog: log
        )

        _ = await toolbox.execute(AIToolCall(
            id: "1", name: "create_task", arguments: .object([:])
        ))

        let entry = try #require(try await log.recent().first)
        #expect(entry.status == .failed)
        #expect(entry.error != nil)
        #expect(!entry.isUndoable)
    }

    @Test("Oluşturulan görev geri alınınca gerçekten silinir")
    func undoRemovesTask() async throws {
        let context = try await TestDatabase()
        let tasks = TaskService(database: context.database)
        let notes = NoteService(database: context.database)
        let projects = ProjectService(database: context.database)
        let memory = MemoryService(database: context.database)
        let log = ActionLogService(database: context.database)

        let toolbox = ATAKToolbox(
            tasks: tasks, notes: notes, projects: projects,
            memory: memory, actionLog: log
        )
        let undo = UndoService(
            log: log, tasks: tasks, notes: notes, projects: projects,
            memory: memory, calendar: CalendarService()
        )

        _ = await toolbox.execute(AIToolCall(
            id: "1", name: "create_task", arguments: .object(["title": "Silinecek görev"])
        ))
        #expect(try await tasks.list(.all).count == 1)

        let candidate = try #require(try await undo.candidate())
        let described = try await undo.undo(candidate)

        #expect(described.contains("Silinecek görev"))
        #expect(try await tasks.list(.all).isEmpty)
    }

    @Test("Geri alınan iş ikinci kez aday olmaz")
    func undoneActionIsNotOfferedAgain() async throws {
        let context = try await TestDatabase()
        let tasks = TaskService(database: context.database)
        let notes = NoteService(database: context.database)
        let projects = ProjectService(database: context.database)
        let memory = MemoryService(database: context.database)
        let log = ActionLogService(database: context.database)

        let toolbox = ATAKToolbox(
            tasks: tasks, notes: notes, projects: projects, actionLog: log
        )
        let undo = UndoService(
            log: log, tasks: tasks, notes: notes, projects: projects,
            memory: memory, calendar: CalendarService()
        )

        _ = await toolbox.execute(AIToolCall(
            id: "1", name: "create_note", arguments: .object(["body": "geri alınacak not"])
        ))

        let candidate = try #require(try await undo.candidate())
        try await undo.undo(candidate)

        #expect(try await undo.candidate() == nil)
    }

    @Test("Okuma araçları geri alınabilir iş üretmez")
    func readOnlyToolsAreNotUndoable() async throws {
        let context = try await TestDatabase()
        let log = ActionLogService(database: context.database)
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database),
            actionLog: log
        )

        _ = await toolbox.execute(AIToolCall(
            id: "1", name: "list_tasks", arguments: .object([:])
        ))

        let entry = try #require(try await log.recent().first)
        #expect(entry.status == .succeeded)
        #expect(!entry.isUndoable)
    }
}

// MARK: - Onaya bağlı araçlar

@Suite("Onaya bağlı araçlar")
struct ConsentedToolTests {

    /// Onay kapısı bağlanmamışsa riskli araç **çalışmamalı**. Varsayılanın
    /// "izin ver" olması, yapılandırma hatasını sessiz bir güvenlik açığına
    /// çevirirdi.
    @Test("Kapı bağlı değilken onay isteyen araç reddedilir")
    func defaultsToDenied() async throws {
        let context = try await TestDatabase()
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database),
            calendar: CalendarService()
        )

        let result = await toolbox.execute(AIToolCall(
            id: "1", name: "create_calendar_event",
            arguments: .object(["title": "Toplantı", "date": "2026-09-01", "time": "10:00"])
        ))

        #expect(result.isError)
        #expect(result.summary == "onaylanmadı")
    }

    @Test("Reddedilen çağrı defterde 'denied' olarak durur")
    func denialIsRecorded() async throws {
        let context = try await TestDatabase()
        let log = ActionLogService(database: context.database)
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database),
            calendar: CalendarService(),
            actionLog: log,
            consent: FixedConsent(.denied)
        )

        _ = await toolbox.execute(AIToolCall(
            id: "1", name: "create_calendar_event",
            arguments: .object(["title": "Toplantı", "date": "2026-09-01", "time": "10:00"])
        ))

        let entry = try #require(try await log.recent().first)
        #expect(entry.status == .denied)
        #expect(entry.requiredConsent)
        #expect(entry.consentGrantedAt == nil)
    }

    @Test("Onay gerektirmeyen araç kapıya hiç uğramaz")
    func lowRiskToolSkipsGate() async throws {
        let context = try await TestDatabase()
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database),
            // Kapı her şeyi reddediyor; yine de düşük riskli araç çalışmalı.
            consent: FixedConsent(.denied)
        )

        let result = await toolbox.execute(AIToolCall(
            id: "1", name: "create_task", arguments: .object(["title": "Onaysız görev"])
        ))
        #expect(!result.isError)
    }
}

// MARK: - Takvim (saf mantık)

@Suite("Takvim boşluk hesabı")
struct CalendarLogicTests {

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: TaskService.todayBounds().start
        ) ?? Date()
    }

    @Test("Çakışan meşgul bloklar birleşir")
    func overlappingBlocksMerge() {
        let merged = CalendarService.merged([
            (date(9), date(11)),
            (date(10), date(12)),
            (date(14), date(15)),
        ])

        #expect(merged.count == 2)
        #expect(merged[0].start == date(9))
        #expect(merged[0].end == date(12))
    }

    @Test("Bitişik bloklar tek blok sayılır")
    func adjacentBlocksMerge() {
        let merged = CalendarService.merged([
            (date(9), date(10)),
            (date(10), date(11)),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].end == date(11))
    }

    @Test("Sırasız gelen bloklar da doğru birleşir")
    func unsortedBlocksMerge() {
        let merged = CalendarService.merged([
            (date(14), date(15)),
            (date(9), date(10)),
        ])
        #expect(merged.count == 2)
        #expect(merged[0].start == date(9))
    }
}

// MARK: - Odak zamanlayıcısı

@Suite("Odak seansları")
struct FocusTimerTests {

    @Test("Biten seans kaydedilir ve bugünün toplamına girer")
    func sessionIsPersisted() async throws {
        let context = try await TestDatabase()
        let service = TimerSessionService(database: context.database)

        try await service.record(TimerSession(
            plannedMinutes: 25, actualMinutes: 25, note: "derin çalışma"
        ))

        let sessions = try await service.recent()
        #expect(sessions.count == 1)
        #expect(sessions.first?.completed == true)
        #expect(try await service.focusedMinutesToday() == 25)
    }

    @Test("Yarım bırakılan seans tamamlanmamış sayılır")
    func partialSessionIsIncomplete() async throws {
        let context = try await TestDatabase()
        let service = TimerSessionService(database: context.database)

        try await service.record(TimerSession(plannedMinutes: 25, actualMinutes: 7))
        let session = try #require(try await service.recent().first)

        #expect(!session.completed)
        #expect(try await service.focusedMinutesToday() == 7)
    }

    @Test("Molalar odak toplamına sayılmaz")
    func breaksAreNotCountedAsFocus() async throws {
        let context = try await TestDatabase()
        let service = TimerSessionService(database: context.database)

        try await service.record(TimerSession(kind: .shortBreak, plannedMinutes: 5, actualMinutes: 5))
        #expect(try await service.focusedMinutesToday() == 0)
    }
}

// MARK: - Özel oturum ve denetim defteri

@Suite("Özel oturumda denetim ve geri alma")
struct PrivateModeActionTests {

    /// Bulunan hata: özel oturumda sohbet satırı veritabanına yazılmadığı için
    /// denetim kaydı ona bağlanamıyor, yabancı anahtar ihlaliyle sessizce
    /// düşüyordu. Sonuç: özel oturumda yapılan iş deftere hiç girmiyor ve
    /// geri alınamıyordu — oysa aracın oluşturduğu görev diskte duruyordu.
    @Test("Sohbete bağlanmamış iş yine de deftere girer")
    func actionWithoutConversationIsLogged() async throws {
        let context = try await TestDatabase()
        let log = ActionLogService(database: context.database)
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database),
            actionLog: log
        )

        _ = await toolbox.execute(
            AIToolCall(id: "1", name: "create_task", arguments: .object(["title": "özel görev"])),
            conversationID: nil
        )

        let entries = try await log.recent()
        #expect(entries.count == 1)
        #expect(entries.first?.conversationID == nil)
        #expect(entries.first?.isUndoable == true)
    }

    /// Var olmayan bir sohbet kimliği verilirse kayıt düşer. ChatEngine özel
    /// oturumda `nil` geçerek bunu engelliyor; bu test o sözleşmeyi koruyor.
    @Test("Var olmayan sohbete bağlı kayıt deftere giremez")
    func danglingConversationIsRejected() async throws {
        let context = try await TestDatabase()
        let log = ActionLogService(database: context.database)
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database),
            actionLog: log
        )

        _ = await toolbox.execute(
            AIToolCall(id: "1", name: "create_task", arguments: .object(["title": "hayalet"])),
            conversationID: UUID()
        )

        #expect(try await log.recent().isEmpty)
    }
}

// MARK: - Geri alma penceresi

@Suite("Geri alma zaman penceresi")
struct UndoWindowTests {

    /// Sohbetteki şerit turun başlangıcını veriyor. Bu süzgeç olmasaydı,
    /// turda yalnız okuma aracı çalışmış olsa bile önceki bir turun işi
    /// "bu turda yapıldı" gibi önerilirdi.
    @Test("Tur başlangıcından önceki iş aday olmaz")
    func earlierActionIsNotOffered() async throws {
        let context = try await TestDatabase()
        let tasks = TaskService(database: context.database)
        let notes = NoteService(database: context.database)
        let projects = ProjectService(database: context.database)
        let memory = MemoryService(database: context.database)
        let log = ActionLogService(database: context.database)

        let toolbox = ATAKToolbox(tasks: tasks, notes: notes, projects: projects, actionLog: log)
        let undo = UndoService(
            log: log, tasks: tasks, notes: notes, projects: projects,
            memory: memory, calendar: CalendarService()
        )

        _ = await toolbox.execute(AIToolCall(
            id: "1", name: "create_task", arguments: .object(["title": "eski tur"])
        ))

        // Sonraki turun başlangıcı: az önceki işten sonra.
        let laterTurn = Date().addingTimeInterval(1)

        #expect(try await undo.candidate(since: laterTurn) == nil)
        // Süzgeçsiz sorgu onu hâlâ bulabilmeli — kayıt kaybolmuş değil.
        #expect(try await undo.candidate() != nil)
    }

    @Test("Tur içinde yapılan iş aday olur")
    func actionInsideTurnIsOffered() async throws {
        let context = try await TestDatabase()
        let tasks = TaskService(database: context.database)
        let notes = NoteService(database: context.database)
        let projects = ProjectService(database: context.database)
        let memory = MemoryService(database: context.database)
        let log = ActionLogService(database: context.database)

        let toolbox = ATAKToolbox(tasks: tasks, notes: notes, projects: projects, actionLog: log)
        let undo = UndoService(
            log: log, tasks: tasks, notes: notes, projects: projects,
            memory: memory, calendar: CalendarService()
        )

        let turnStart = Date().addingTimeInterval(-1)
        _ = await toolbox.execute(AIToolCall(
            id: "1", name: "create_note", arguments: .object(["body": "bu turda"])
        ))

        let candidate = try #require(try await undo.candidate(since: turnStart))
        #expect(candidate.undo?.label == "bu turda")
    }
}
