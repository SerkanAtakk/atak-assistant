import Foundation

public enum ProjectStatus: String, Sendable, Codable, CaseIterable, Identifiable {
    case active
    case paused
    case completed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .active:    return "Aktif"
        case .paused:    return "Beklemede"
        case .completed: return "Tamamlandı"
        }
    }
}

/// Proje rengi. Ham SwiftUI `Color` yerine sembolik değer saklanır ki
/// veritabanı tema değişiminden etkilenmesin.
public enum ProjectColor: String, Sendable, Codable, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .blue:   return "Mavi"
        case .purple: return "Mor"
        case .pink:   return "Pembe"
        case .red:    return "Kırmızı"
        case .orange: return "Turuncu"
        case .yellow: return "Sarı"
        case .green:  return "Yeşil"
        case .teal:   return "Turkuaz"
        case .gray:   return "Gri"
        }
    }
}

public struct Project: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var details: String
    public var status: ProjectStatus
    public var color: ProjectColor
    public var deadline: Date?
    public var createdAt: Date
    public var archived: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        details: String = "",
        status: ProjectStatus = .active,
        color: ProjectColor = .blue,
        deadline: Date? = nil,
        createdAt: Date = Date(),
        archived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.status = status
        self.color = color
        self.deadline = deadline
        self.createdAt = createdAt
        self.archived = archived
    }
}

extension Project {
    init(row: Row) throws {
        guard let id = row.uuid("id"), let name = row.string("name") else {
            throw ATAKError.database("project satırı okunamadı")
        }
        self.init(
            id: id,
            name: name,
            details: row.string("description") ?? "",
            status: ProjectStatus(rawValue: row.string("status") ?? "") ?? .active,
            color: ProjectColor(rawValue: row.string("color") ?? "") ?? .blue,
            deadline: row.date("deadline"),
            createdAt: row.date("created_at") ?? Date(),
            archived: row.bool("archived") ?? false
        )
    }
}

/// Proje ilerleme özeti — görev sayımlarından türetilir, saklanmaz.
public struct ProjectProgress: Sendable, Equatable {
    public let total: Int
    public let done: Int

    public init(total: Int, done: Int) {
        self.total = total
        self.done = done
    }

    public var fraction: Double {
        total == 0 ? 0 : Double(done) / Double(total)
    }

    public var percentText: String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
