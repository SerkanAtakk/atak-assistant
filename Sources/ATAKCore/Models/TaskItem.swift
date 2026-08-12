import Foundation

/// Görev durumu.
public enum TaskStatus: String, Sendable, Codable, CaseIterable, Identifiable {
    case todo
    case inProgress
    case blocked
    case done
    case cancelled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .todo:       return "Yapılacak"
        case .inProgress: return "Devam ediyor"
        case .blocked:    return "Engellendi"
        case .done:       return "Tamamlandı"
        case .cancelled:  return "İptal"
        }
    }

    public var systemImage: String {
        switch self {
        case .todo:       return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .blocked:    return "exclamationmark.circle"
        case .done:       return "checkmark.circle.fill"
        case .cancelled:  return "xmark.circle"
        }
    }

    public var isOpen: Bool { self == .todo || self == .inProgress || self == .blocked }
}

/// Görev önceliği. Ham değer sıralamada kullanılır (yüksek = önemli).
public enum TaskPriority: Int, Sendable, Codable, CaseIterable, Identifiable, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .low:    return "Düşük"
        case .normal: return "Normal"
        case .high:   return "Yüksek"
        case .urgent: return "Acil"
        }
    }

    public var systemImage: String {
        switch self {
        case .low:    return "arrow.down"
        case .normal: return "minus"
        case .high:   return "arrow.up"
        case .urgent: return "exclamationmark.2"
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Bir görev.
///
/// `Task` adı Swift Concurrency ile çakıştığı için `TaskItem`.
public struct TaskItem: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var projectID: UUID?
    public var parentTaskID: UUID?
    public var title: String
    public var notes: String
    public var status: TaskStatus
    public var priority: TaskPriority
    public var startAt: Date?
    public var dueAt: Date?
    public var estimatedMinutes: Int?
    public var actualMinutes: Int?
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var sortOrder: Double
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        parentTaskID: UUID? = nil,
        title: String,
        notes: String = "",
        status: TaskStatus = .todo,
        priority: TaskPriority = .normal,
        startAt: Date? = nil,
        dueAt: Date? = nil,
        estimatedMinutes: Int? = nil,
        actualMinutes: Int? = nil,
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sortOrder: Double = 0,
        tags: [String] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.parentTaskID = parentTaskID
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.startAt = startAt
        self.dueAt = dueAt
        self.estimatedMinutes = estimatedMinutes
        self.actualMinutes = actualMinutes
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.tags = tags
    }

    // MARK: - Türetilmiş bilgiler

    public var isOverdue: Bool {
        guard let dueAt, status.isOpen else { return false }
        return dueAt < Date()
    }

    public var isDueToday: Bool {
        guard let dueAt else { return false }
        return Calendar.current.isDateInToday(dueAt)
    }

    /// Planlama motorunun kullandığı aciliyet skoru (MIMARI §14 hazırlığı).
    public var urgencyScore: Double {
        var score = Double(priority.rawValue) * 10

        if let dueAt, status.isOpen {
            let hoursLeft = dueAt.timeIntervalSinceNow / 3600
            if hoursLeft < 0 {
                score += 100                       // gecikmiş
            } else if hoursLeft < 24 {
                score += 60
            } else if hoursLeft < 72 {
                score += 30
            } else if hoursLeft < 168 {
                score += 10
            }
        }
        return score
    }
}

// MARK: - Satır eşlemesi

extension TaskItem {
    init(row: Row) throws {
        guard let id = row.uuid("id"), let title = row.string("title") else {
            throw ATAKError.database("task satırı okunamadı")
        }
        self.init(
            id: id,
            projectID: row.uuid("project_id"),
            parentTaskID: row.uuid("parent_task_id"),
            title: title,
            notes: row.string("notes") ?? "",
            status: TaskStatus(rawValue: row.string("status") ?? "") ?? .todo,
            priority: TaskPriority(rawValue: row.intValue("priority", default: 1)) ?? .normal,
            startAt: row.date("start_at"),
            dueAt: row.date("due_at"),
            estimatedMinutes: row.int("estimated_minutes").map(Int.init),
            actualMinutes: row.int("actual_minutes").map(Int.init),
            completedAt: row.date("completed_at"),
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date(),
            sortOrder: row.double("sort_order") ?? 0,
            tags: []
        )
    }
}
