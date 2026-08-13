import Foundation
import Combine

/// Hangi bölümün açık olduğunu tutar.
///
/// `@State` bu toolchain'de kullanılamadığı için (MIMARI §0) tüm görünüm
/// durumu `ObservableObject` üzerinde yaşar. Bu zaten spec'in istediği
/// ViewModel mimarisi.
@MainActor
public final class AppRouter: ObservableObject {
    /// Uygulama sohbetle açılır; diğer ekranlar elle düzenleme içindir.
    @Published public var section: AppSection = .chat
    @Published public var selectedProjectID: UUID?
    @Published public var selectedTaskID: UUID?
    @Published public var isSidebarVisible = true
    /// Başka bir ekrandan sohbete taşınan taslak. Sohbet ekranı değeri bir
    /// kez tüketir; böylece Dashboard'da yazılan metin kaybolmaz.
    @Published public var pendingChatPrompt: String?

    public init() {}

    public func select(_ section: AppSection) {
        self.section = section
    }

    public func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    public func openProject(_ id: UUID) {
        selectedProjectID = id
        section = .projects
    }

    public func openTask(_ id: UUID) {
        selectedTaskID = id
        section = .tasks
    }

    public func openChat(with prompt: String? = nil) {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingChatPrompt = trimmed?.isEmpty == false ? trimmed : nil
        section = .chat
    }

    public func consumeChatPrompt() -> String? {
        defer { pendingChatPrompt = nil }
        return pendingChatPrompt
    }
}
