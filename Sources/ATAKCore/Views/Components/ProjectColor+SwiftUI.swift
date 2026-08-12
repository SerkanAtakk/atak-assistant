import SwiftUI

extension ProjectColor {
    /// Sembolik proje rengini sistem rengine çevirir.
    /// Renk veritabanında ad olarak durur; tema değişimi veriyi etkilemez.
    public var color: Color {
        switch self {
        case .blue:   return .blue
        case .purple: return .purple
        case .pink:   return .pink
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .teal:   return .teal
        case .gray:   return .gray
        }
    }
}
