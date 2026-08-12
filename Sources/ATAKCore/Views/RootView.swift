import SwiftUI

/// Uygulamanın kök görünümü: kenar çubuğu + içerik.
///
/// Tema buradan tek noktadan enjekte edilir; alt görünümler renk sabiti
/// kullanmaz, `@Environment(\.atakTheme)` okur.
public struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 208, max: 260)
        } detail: {
            content
        }
        .environment(\.atakTheme, environment.theme)
        .tint(environment.theme.accent)
        .task {
            await environment.bootstrap()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch environment.status {
        case .starting:
            LoadingView()
        case .failed(let message):
            StartupFailureView(message: message)
        case .ready:
            destination
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch router.section {
        case .chat:      ChatView()
        case .dashboard: DashboardView().atakBackground()
        case .tasks:     TasksView().atakBackground()
        case .projects:  ProjectsView().atakBackground()
        case .notes:     NotesView().atakBackground()
        case .settings:  SettingsView().atakBackground()
        case .calendar:
            ComingSoonView(section: .calendar, note: "Takvim entegrasyonu A10 adımında geliyor.")
                .atakBackground()
        case .focus:
            ComingSoonView(section: .focus, note: "Pomodoro ve odak seansı A12 adımında geliyor.")
                .atakBackground()
        case .memory:
            ComingSoonView(section: .memory, note: "ATAK Hafızası v0.2'de açılıyor.")
                .atakBackground()
        }
    }
}

// MARK: - Kenar çubuğu

struct SidebarView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.atakTheme) private var theme

    var body: some View {
        List(selection: sectionBinding) {
            Section {
                ForEach(AppSection.primary) { row($0) }
            }
            Section { ForEach(AppSection.work) { row($0) } } header: {
                TechLabel("Çalışma")
            }
            Section { ForEach(AppSection.tools) { row($0) } } header: {
                TechLabel("ATAK")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Hairline()
                HStack {
                    StatusIndicator(state: environment.agentState)
                    Spacer()
                    Text("v\(AppInfo.version)")
                        .font(theme.labelFont(size: 9.5))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func row(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }

    /// `@State` bu toolchain'de kullanılamadığı için seçim doğrudan router'a bağlanır.
    private var sectionBinding: Binding<AppSection?> {
        Binding(
            get: { router.section },
            set: { if let value = $0 { router.select(value) } }
        )
    }
}

// MARK: - Durum görünümleri

struct LoadingView: View {
    @Environment(\.atakTheme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            TechLabel("ATAK hazırlanıyor", color: theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .atakBackground()
    }
}

struct StartupFailureView: View {
    @Environment(\.atakTheme) private var theme
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.warning)
            Text("ATAK başlatılamadı")
                .font(theme.titleFont(size: 18))
                .foregroundStyle(theme.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .atakBackground()
    }
}

struct ComingSoonView: View {
    @Environment(\.atakTheme) private var theme
    let section: AppSection
    let note: String

    var body: some View {
        EmptyStateView(systemImage: section.systemImage, title: section.title, message: note)
            .navigationTitle(section.title)
    }
}
