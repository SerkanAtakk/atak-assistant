import Foundation

/// ATAK'ın yaptığı son işi geri alır (MIMARI §5: orta riskli işler geri
/// alınabilir olmalı).
///
/// Geri alma, "onay sormadan çalıştır" kararının bedelidir: ATAK görev ve not
/// oluştururken kullanıcıyı durdurup sormaz, çünkü yanlış yaparsa tek tıkla
/// geri alınabiliyor.
public struct UndoService: Sendable {

    private let log: ActionLogService
    private let tasks: TaskService
    private let notes: NoteService
    private let projects: ProjectService
    private let memory: MemoryService
    private let calendar: CalendarService

    public init(
        log: ActionLogService,
        tasks: TaskService,
        notes: NoteService,
        projects: ProjectService,
        memory: MemoryService,
        calendar: CalendarService
    ) {
        self.log = log
        self.tasks = tasks
        self.notes = notes
        self.projects = projects
        self.memory = memory
        self.calendar = calendar
    }

    /// Geri alınabilecek son iş — arayüzde "Geri al" düğmesinin metni buradan.
    ///
    /// - Parameter since: Sohbet şeridi turun başlangıcını verir; böylece
    ///   yalnız o turda olan bir iş önerilir.
    public func candidate(since: Date? = nil) async throws -> AssistantAction? {
        try await log.lastUndoable(since: since)
    }

    /// Verilen işi geri alır ve defterde işaretler.
    ///
    /// Hedef kayıt kullanıcı tarafından çoktan silinmiş olabilir; bu bir hata
    /// değil, istenen sonucun zaten gerçekleşmiş olmasıdır — defter yine de
    /// işaretlenir ki aynı iş listede takılı kalmasın.
    @discardableResult
    public func undo(_ action: AssistantAction) async throws -> String {
        guard let token = action.undo else {
            throw ATAKError.unsupported("Bu iş geri alınamaz.")
        }

        switch token.kind {
        case .taskCreated:
            if let id = UUID(uuidString: token.targetID) {
                try await tasks.delete(id)
            }
        case .taskCompleted:
            if let id = UUID(uuidString: token.targetID) {
                try await tasks.setCompleted(id, false)
            }
        case .noteCreated:
            if let id = UUID(uuidString: token.targetID) {
                try await notes.delete(id)
            }
        case .projectCreated:
            if let id = UUID(uuidString: token.targetID) {
                try await projects.delete(id)
            }
        case .memoryStored:
            if let id = UUID(uuidString: token.targetID) {
                try await memory.forget(id)
            }
        case .calendarEventCreated:
            try await calendar.deleteEvent(identifier: token.targetID)
        }

        try await log.markUndone(action.id)
        Log.app.info("Geri alındı: \(token.kind.rawValue, privacy: .public)")
        return token.undoDescription
    }
}
