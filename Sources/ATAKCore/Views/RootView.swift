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
        HStack(spacing: 0) {
            if router.isSidebarVisible {
                SidebarView()
                    .frame(width: 224)

                Rectangle()
                    .fill(environment.theme.hairline)
                    .frame(width: environment.theme.hairlineWidth)
            }

            content
                .id(router.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case .calendar:  CalendarView().atakBackground()
        case .focus:     FocusView().atakBackground()
        case .memory:    MemoryView().atakBackground()
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
        .scrollContentBackground(.hidden)
        .background(theme.surface.opacity(theme.identifier == .hud ? 0.78 : 0.96))
        .safeAreaInset(edge: .top) {
            brandHeader
        }
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    private var brandHeader: some View {
        Button {
            router.select(.chat)
        } label: {
            HStack(spacing: 11) {
                ATAKLogoMark(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ATAK")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Kişisel asistan")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(theme.surface.opacity(0.98))
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Hairline()
            Button {
                router.select(environment.isAIReady ? .chat : .settings)
            } label: {
                HStack(spacing: 9) {
                    StatusIndicator(state: environment.isAIReady ? environment.agentState : .offline, compact: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(environment.isAIReady ? environment.agentState.displayName : "Kurulum gerekli")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                        Text(environment.isAIReady ? environment.aiConfiguration.info.displayName : "Yapay zekâyı bağla")
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("v\(AppInfo.version)")
                        .font(theme.labelFont(size: 9))
                        .foregroundStyle(theme.textTertiary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
        }
        .background(theme.surface.opacity(0.98))
    }

    private func row(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .font(.system(size: 13, weight: router.section == section ? .semibold : .regular))
            .foregroundStyle(router.section == section ? theme.textPrimary : theme.textSecondary)
            .padding(.vertical, 3)
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
            ATAKLogoMark(size: 48)
            ProgressView().controlSize(.small)
            VStack(spacing: 3) {
                Text("Çalışma alanın hazırlanıyor")
                    .font(theme.titleFont(size: 15))
                    .foregroundStyle(theme.textPrimary)
                Text("Verilerin ve asistan bağlantın kontrol ediliyor.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
            }
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
