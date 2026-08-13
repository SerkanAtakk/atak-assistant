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

    @Published public var filter: TaskListFilter = .open {
        didSet { if filter != oldValue { reload() } }
    }
    @Published public var searchText = "" {
        didSet { if searchText != oldValue { reload() } }
    }
    @Published public var newTaskTitle = ""

    /// Seçilen görevin düzenlenebilir kopyası. Kaydetme açık biçimde yapılır.
    @Published public var selectedID: UUID? {
        didSet { if selectedID != oldValue { loadDraft() } }
    }
    @Published public var draft: TaskItem?

    private var taskService: TaskService?
    private var projectService: ProjectService?
    private weak var router: AppRouter?
    private var reloadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var loadVersion: UInt64 = 0
    private var saveVersion: UInt64 = 0

    public init() {}

    init(
        taskService: TaskService,
        projectService: ProjectService,
        router: AppRouter? = nil
    ) {
        self.taskService = taskService
        self.projectService = projectService
        self.router = router
    }

    public func configure(_ environment: AppEnvironment) {
        guard taskService == nil else { return }
        // Derin bağlantı filtresini servis bağlanmadan seç; böylece didSet
        // gereksiz bir ikinci yükleme kuyruğa koymaz.
        if environment.router.selectedTaskID != nil { filter = .all }
        taskService = environment.tasks
        projectService = environment.projects
        router = environment.router
        reloadTask?.cancel()
        reloadTask = nil
    }

    // MARK: - Yükleme

    public func load() async {
        guard let taskService else { return }
        loadVersion &+= 1
        let version = loadVersion
        isLoading = true

        do {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let serviceFilter: TaskFilter = trimmed.isEmpty ? filter.serviceFilter : .search(trimmed)
            let loadedTasks = try await taskService.list(serviceFilter)
            let loadedProjects = try await projectService?.all() ?? []

            // Daha yeni bir arama/filtre isteği başladıysa eski sonuç arayüzü
            // geriye doğru güncellemesin.
            guard version == loadVersion else { return }
            tasks = loadedTasks
            projects = loadedProjects

            if let requested = router?.selectedTaskID,
               tasks.contains(where: { $0.id == requested }) {
                selectedID = requested
                router?.selectedTaskID = nil
            }

            // Seçili görev listeden düştüyse seçimi temizle.
            if let selectedID, !tasks.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            } else {
                // Seçim aynı kalsa bile yeniden okunan veriyi inspectora taşı.
                loadDraft()
            }
        } catch {
            if version == loadVersion { errorMessage = error.localizedDescription }
        }

        if version == loadVersion {
            isLoading = false
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
        saveTask?.cancel()
        saveTask = nil
        saveVersion &+= 1
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
        saveTask?.cancel()
        saveVersion &+= 1
        let version = saveVersion

        // Picker'lar hızlı değiştirildiğinde yalnız son snapshot diske gider.
        saveTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await persistDraft(current, version: version)
        }
    }

    public func saveDraft() async {
        guard let draft else { return }
        saveTask?.cancel()
        saveTask = nil
        saveVersion &+= 1
        await persistDraft(draft, version: saveVersion)
    }

    private func persistDraft(_ snapshot: TaskItem, version: UInt64) async {
        guard let taskService else { return }
        guard !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await taskService.update(snapshot)
            guard version == saveVersion else { return }
            await load()
            guard version == saveVersion else { return }
            // `load()` görevi aktif filtreden düşürdüyse seçimi ve taslağı nil
            // bırakır; eski snapshot inspectorı yeniden diriltmez.
            if selectedID == snapshot.id {
                draft = tasks.first { $0.id == snapshot.id }
            }
            saveTask = nil
        } catch {
            if version == saveVersion {
                saveTask = nil
                errorMessage = error.localizedDescription
            }
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
