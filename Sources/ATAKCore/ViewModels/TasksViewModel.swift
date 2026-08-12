import Foundation
import Combine

/// Görev listesinin kullanıcıya gösterilen filtreleri.
public enum TaskListFilter: String, CaseIterable, Identifiable, Sendable {
    case today
    case open
    case overdue
    case completed
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today:     return "Bugün"
        case .open:      return "Açık"
        case .overdue:   return "Gecikmiş"
        case .completed: return "Tamamlanan"
        case .all:       return "Tümü"
        }
    }

    var serviceFilter: TaskFilter {
        switch self {
        case .today:     return .today
        case .open:      return .open
        case .overdue:   return .overdue
        case .completed: return .completed
        case .all:       return .all
        }
    }
}

@MainActor
public final class TasksViewModel: ObservableObject {

    @Published public private(set) var tasks: [TaskItem] = []
    @Published public private(set) var projects: [Project] = []
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    @Published public var filter: TaskListFilter = .open { didSet { reload() } }
    @Published public var searchText = "" { didSet { reload() } }
    @Published public var newTaskTitle = ""

    /// Seçilen görevin düzenlenebilir kopyası. Kaydetme açık biçimde yapılır.
    @Published public var selectedID: UUID? { didSet { loadDraft() } }
    @Published public var draft: TaskItem?

    private var taskService: TaskService?
    private var projectService: ProjectService?
    private var reloadTask: Task<Void, Never>?

    public init() {}

    public func configure(_ environment: AppEnvironment) {
        guard taskService == nil else { return }
        taskService = environment.tasks
        projectService = environment.projects
    }

    // MARK: - Yükleme

    public func load() async {
        guard let taskService else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let serviceFilter: TaskFilter = trimmed.isEmpty ? filter.serviceFilter : .search(trimmed)
            tasks = try await taskService.list(serviceFilter)
            projects = try await projectService?.all() ?? []

            // Seçili görev listeden düştüyse seçimi temizle.
            if let selectedID, !tasks.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Filtre/arama değişince çağrılır; art arda gelen değişiklikleri sadeleştirir.
    private func reload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    private func loadDraft() {
        guard let selectedID else { draft = nil; return }
        draft = tasks.first { $0.id == selectedID }
    }

    // MARK: - Eylemler

    public func addTask() async {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let taskService else { return }

        do {
            // "Bugün" filtresindeyken eklenen görev listede kalsın diye bugüne atanır.
            let due: Date? = filter == .today ? Date() : nil
            let created = try await taskService.create(title: title, dueAt: due)
            newTaskTitle = ""
            await load()
            selectedID = created.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggleCompleted(_ task: TaskItem) async {
        guard let taskService else { return }
        do {
            try await taskService.setCompleted(task.id, task.status != .done)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ id: UUID) async {
        guard let taskService else { return }
        do {
            try await taskService.delete(id)
            if selectedID == id { selectedID = nil }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Taslağı düzenleyip anında kaydeder (seçici/anahtar değişiklikleri için).
    public func mutateDraft(_ change: (inout TaskItem) -> Void) {
        guard var current = draft else { return }
        change(&current)
        draft = current
        Task { await saveDraft() }
    }

    public func saveDraft() async {
        guard let draft, let taskService else { return }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await taskService.update(draft)
            await load()
            // Yeniden yükleme taslağı tazeler; seçim korunur.
            self.draft = tasks.first { $0.id == draft.id } ?? draft
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Görüntüleme yardımcıları

    public func projectName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return projects.first { $0.id == id }?.name
    }

    public func projectColor(for id: UUID?) -> ProjectColor? {
        guard let id else { return nil }
        return projects.first { $0.id == id }?.color
    }

    public var emptyStateMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\"\(searchText)\" için görev bulunamadı."
        }
        switch filter {
        case .today:     return "Bugün için planlanmış görev yok."
        case .open:      return "Açık görevin yok. Aşağıdan yeni bir görev ekleyebilirsin."
        case .overdue:   return "Gecikmiş görevin yok."
        case .completed: return "Henüz tamamlanmış görev yok."
        case .all:       return "Henüz görev yok. Aşağıdan ilkini ekle."
        }
    }
}
