import Foundation
import Combine

@MainActor
public final class DashboardViewModel: ObservableObject {

    @Published public private(set) var topTasks: [TaskItem] = []
    @Published public private(set) var openCount = 0
    @Published public private(set) var dueTodayCount = 0
    @Published public private(set) var overdueCount = 0
    @Published public private(set) var activeProjects: [Project] = []
    @Published public private(set) var suggestion: String?
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    @Published public var askText = ""

    private var taskService: TaskService?
    private var projectService: ProjectService?

    public init() {}

    public func configure(_ environment: AppEnvironment) {
        guard taskService == nil else { return }
        taskService = environment.tasks
        projectService = environment.projects
    }

    public func load() async {
        guard let taskService else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let counts = try await taskService.counts()
            openCount = counts.open
            dueTodayCount = counts.dueToday
            overdueCount = counts.overdue
            topTasks = try await taskService.topPriorities(limit: 3)
            activeProjects = try await projectService?.all().filter { $0.status == .active } ?? []
            suggestion = makeSuggestion()
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

    public var greeting: String { DateFormat.greeting() }

    public var todayLine: String {
        DateFormat.weekday(Date()) + ", " + DateFormat.dayAndMonth(Date())
    }

    /// v0.1'de öneri kural tabanlıdır.
    ///
    /// A7'de AI bağlandığında bu metin `PlannerEngine` çıktısıyla değişecek;
    /// arayüz aynı kaldığı için o geçiş yalnız bu fonksiyonu etkiler.
    private func makeSuggestion() -> String? {
        if overdueCount > 0 {
            let plural = overdueCount == 1 ? "bir işin" : "\(overdueCount) işin"
            return "Son tarihi geçmiş \(plural) var. Güne bunlarla başlamak, listenin geri kalanını rahatlatır."
        }
        if dueTodayCount > 0 {
            let estimated = topTasks.compactMap(\.estimatedMinutes).reduce(0, +)
            if estimated > 0 {
                return "Bugün biten \(dueTodayCount) işin var; öncelikli olanlar için yaklaşık \(DateFormat.duration(minutes: estimated)) ayırman gerekiyor."
            }
            return "Bugün biten \(dueTodayCount) işin var. En kritik olanı önce bitirmek iyi bir başlangıç olur."
        }
        if openCount == 0 {
            return "Açık görevin yok. Yeni bir hedef eklemek veya haftayı planlamak için iyi bir an."
        }
        if let urgent = topTasks.first, urgent.priority >= .high {
            return "Bugün için son tarihli iş yok ama \"\(urgent.title)\" yüksek öncelikli. Zamanın varken onu ilerletebilirsin."
        }
        return nil
    }
}
