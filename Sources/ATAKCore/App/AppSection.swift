import Foundation

/// Kenar çubuğundaki ana bölümler (MIMARI §13).
public enum AppSection: String, Sendable, CaseIterable, Identifiable, Codable {
    case dashboard
    case chat
    case tasks
    case projects
    case calendar
    case notes
    case focus
    case memory
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: return "Bugün"
        case .chat:      return "Sohbet"
        case .tasks:     return "Görevler"
        case .projects:  return "Projeler"
        case .calendar:  return "Takvim"
        case .notes:     return "Notlar"
        case .focus:     return "Odak"
        case .memory:    return "ATAK Hafızası"
        case .settings:  return "Ayarlar"
        }
    }

    public var systemImage: String {
        switch self {
        case .dashboard: return "sun.max"
        case .chat:      return "bubble.left.and.bubble.right"
        case .tasks:     return "checklist"
        case .projects:  return "square.stack.3d.up"
        case .calendar:  return "calendar"
        case .notes:     return "note.text"
        case .focus:     return "timer"
        case .memory:    return "brain"
        case .settings:  return "gearshape"
        }
    }

    /// Kenar çubuğu gruplaması. Sohbet ilk sırada — uygulamanın merkezi o.
    public static let primary: [AppSection] = [.chat, .dashboard]
    public static let work: [AppSection] = [.tasks, .projects, .calendar, .notes]
    public static let tools: [AppSection] = [.focus, .memory, .settings]
}
