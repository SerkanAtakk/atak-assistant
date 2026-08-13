import Foundation
import Combine

@MainActor
public final class ProjectsViewModel: ObservableObject {

    @Published public private(set) var projects: [Project] = []
    @Published public private(set) var progress: [UUID: ProjectProgress] = [:]
    @Published public private(set) var projectTasks: [TaskItem] = []
    @Published public var errorMessage: String?

    @Published public var newProjectName = ""
    @Published public var selectedID: UUID? { didSet { loadDraftAndTasks() } }
    @Published public var draft: Project?

    private var projectService: ProjectService?
    private var taskService: TaskService?
    private weak var router: AppRouter?

    public init() {}

    public func configure(_ environment: AppEnvironment) {
        guard projectService == nil else { return }
        projectService = environment.projects
        taskService = environment.tasks
        router = environment.router
    }

    public func load() async {
        guard let projectService else { return }
        do {
            projects = try await projectService.all()
            progress = try await projectService.progressByProject()
            if let requested = router?.selectedProjectID,
               projects.contains(where: { $0.id == requested }) {
                selectedID = requested
                router?.selectedProjectID = nil
            }
            if let selectedID, !projects.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            } else {
                loadDraftAndTasks()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadDraftAndTasks() {
        guard let selectedID else {
            draft = nil
            projectTasks = []
            return
        }
        draft = projects.first { $0.id == selectedID }

        Task { [weak self] in
            guard let self, let taskService = self.taskService else { return }
            do {
                self.projectTasks = try await taskService.list(.project(selectedID))
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func addProject() async {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let projectService else { return }
        do {
            let created = try await projectService.create(name: name)
            newProjectName = ""
            await load()
            selectedID = created.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func mutateDraft(_ change: (inout Project) -> Void) {
        guard var current = draft else { return }
        change(&current)
        draft = current
        Task { await saveDraft() }
    }

    public func saveDraft() async {
        guard let draft, let projectService else { return }
        do {
            try await projectService.update(draft)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ id: UUID) async {
        guard let projectService else { return }
        do {
            try await projectService.delete(id)
            selectedID = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func progress(for id: UUID) -> ProjectProgress {
        progress[id] ?? ProjectProgress(total: 0, done: 0)
    }
}
