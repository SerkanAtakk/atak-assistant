import SwiftUI

public struct DashboardView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.atakTheme) private var theme
    @StateObject private var model = DashboardViewModel()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let error = model.errorMessage {
                    InlineNotice("Güncel bilgiler alınamadı", message: error, kind: .error)
                }

                summaryGrid
                prioritiesPanel

                if let suggestion = model.suggestion {
                    suggestionPanel(suggestion)
                }

                projectsPanel
                askPanel
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Bugün")
        .task(id: router.section) {
            guard router.section == .dashboard else { return }
            model.configure(environment)
            await model.load()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            ScreenHeader(
                "\(DateFormat.greeting())\(environment.userName.isEmpty ? "" : ", \(environment.userName)")",
                subtitle: model.todayLine,
                eyebrow: "Günün özeti",
                systemImage: "sun.max.fill"
            )
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                StatusIndicator(state: environment.isAIReady ? environment.agentState : .offline, compact: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(environment.isAIReady ? "Asistan hazır" : "Kurulum gerekli")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text(environment.isAIReady ? environment.aiConfiguration.info.displayName : "Bağlantı yok")
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .panel(raised: true)
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            DashboardMetricCard(
                value: "\(model.openCount)",
                label: "Açık görev",
                detail: model.openCount == 0 ? "Listen temiz" : "Takipte",
                systemImage: "checklist",
                tint: theme.accent
            ) { router.select(.tasks) }

            DashboardMetricCard(
                value: "\(model.dueTodayCount)",
                label: "Bugün bitiyor",
                detail: model.dueTodayCount == 0 ? "Takvim rahat" : "Bugünün odağı",
                systemImage: "calendar.badge.clock",
                tint: theme.warning
            ) { router.select(.tasks) }

            DashboardMetricCard(
                value: "\(model.overdueCount)",
                label: "Gecikmiş",
                detail: model.overdueCount == 0 ? "Her şey yolunda" : "Öncelik ver",
                systemImage: model.overdueCount == 0 ? "checkmark.shield" : "exclamationmark.triangle",
                tint: model.overdueCount == 0 ? theme.success : theme.danger
            ) { router.select(.tasks) }
        }
        .redacted(reason: model.isLoading ? .placeholder : [])
    }

    private var prioritiesPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionTitle("Önceliklerin", detail: model.topTasks.isEmpty ? nil : "ilk \(model.topTasks.count)")
                Button("Tüm görevler") { router.select(.tasks) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.accent)
            }

            if model.topTasks.isEmpty && !model.isLoading {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Öncelikli bir iş görünmüyor")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                        Text("Yeni bir görev ekleyebilir veya ATAK ile gününü planlayabilirsin.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 5)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.topTasks.enumerated()), id: \.element.id) { index, task in
                        priorityRow(task, index: index)
                        if task.id != model.topTasks.last?.id { Hairline() }
                    }
                }
            }
        }
        .padding(17)
        .panel()
        .redacted(reason: model.isLoading ? .placeholder : [])
    }

    private func priorityRow(_ task: TaskItem, index: Int) -> some View {
        HStack(spacing: 11) {
            Button {
                Task { await model.toggleCompleted(task) }
            } label: {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(task.status == .done ? theme.success : theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(task.status == .done ? "Yeniden aç" : "Tamamlandı olarak işaretle")

            Button {
                router.openTask(task.id)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 9) {
                            if let due = task.dueAt {
                                Label(DateFormat.relativeDay(due), systemImage: "calendar")
                                    .foregroundStyle(task.isOverdue ? theme.danger : theme.textSecondary)
                            }
                            if task.priority != .normal {
                                Label(task.priority.displayName, systemImage: task.priority.systemImage)
                                    .foregroundStyle(task.priority >= .high ? theme.warning : theme.textSecondary)
                            }
                        }
                        .font(.system(size: 10.5))
                    }
                    Spacer()
                    Text(String(format: "%02d", index + 1))
                        .font(theme.numericFont(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
    }

    private func suggestionPanel(_ suggestion: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 34)
                .background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                TechLabel("ATAK önerisi", color: theme.accent)
                Text(suggestion)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Birlikte planla") {
                router.openChat(with: "Bugünkü işlerimi önceliklendirip uygulanabilir kısa bir plan çıkar.")
            }
            .buttonStyle(.atakSecondary)
        }
        .padding(17)
        .panel(raised: true, accented: true)
    }

    @ViewBuilder
    private var projectsPanel: some View {
        if !model.activeProjects.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle("Aktif projeler", detail: "\(model.activeProjects.count) proje")
                    Button("Tümünü gör") { router.select(.projects) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accent)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    ForEach(model.activeProjects.prefix(6)) { project in
                        Button {
                            router.openProject(project.id)
                        } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(project.color.color)
                                    .frame(width: 4, height: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.name)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Text(project.deadline.map(DateFormat.relativeDay) ?? "Son tarih yok")
                                        .font(.system(size: 10))
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .padding(12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .panel(raised: true)
                    }
                }
            }
        }
    }

    private var askPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Aklındakini ATAK'a bırak")
                        .font(theme.titleFont(size: 16, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Plan oluştur, bir şeyi not al veya görevlerini düzenle.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Image(systemName: "command")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .padding(6)
                    .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(theme.accent)
                TextField("Örn. Bu haftayı benimle planla", text: $model.askText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { openAsk() }
                Button(action: openAsk) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.atakPrimary)
                .disabled(model.askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .panel(raised: true)
        }
        .padding(18)
        .panel()
    }

    private func openAsk() {
        let prompt = model.askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        model.askText = ""
        router.openChat(with: prompt)
    }
}

private struct DashboardMetricCard: View {
    @Environment(\.atakTheme) private var theme
    let value: String
    let label: String
    let detail: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(theme.numericFont(size: 24, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel(raised: true)
    }
}
