import SwiftUI

public struct DashboardView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = DashboardViewModel()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                summaryRow
                prioritiesSection
                if let suggestion = model.suggestion {
                    SuggestionCard(text: suggestion)
                }
                projectsSection
                askSection
            }
            .padding(26)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Bugün")
        .task {
            model.configure(environment)
            await model.load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.greeting)
                .font(.largeTitle.weight(.semibold))
            Text(model.todayLine)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            SummaryTile(
                value: "\(model.openCount)",
                label: "açık görev",
                systemImage: "checklist",
                tint: .blue
            )
            SummaryTile(
                value: "\(model.dueTodayCount)",
                label: "bugün bitiyor",
                systemImage: "calendar",
                tint: .orange
            )
            SummaryTile(
                value: "\(model.overdueCount)",
                label: "gecikmiş",
                systemImage: "exclamationmark.triangle",
                tint: model.overdueCount > 0 ? .red : .secondary
            )
        }
    }

    private var prioritiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Öncelikler").font(.headline)
                Spacer()
                Button("Tümü") { router.select(.tasks) }
                    .buttonStyle(.link)
            }

            if model.topTasks.isEmpty {
                Text("Öncelikli görev yok.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(model.topTasks.enumerated()), id: \.element.id) { index, task in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                            HStack(spacing: 8) {
                                if let due = task.dueAt {
                                    Label(DateFormat.relativeDay(due), systemImage: "calendar")
                                        .foregroundStyle(task.isOverdue ? Color.red : .secondary)
                                }
                                if task.priority != .normal {
                                    Label(task.priority.displayName, systemImage: task.priority.systemImage)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var projectsSection: some View {
        if !model.activeProjects.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Aktif projeler").font(.headline)
                    Spacer()
                    Button("Tümü") { router.select(.projects) }
                        .buttonStyle(.link)
                }
                FlowRow(items: model.activeProjects) { project in
                    HStack(spacing: 6) {
                        Circle().fill(project.color.color).frame(width: 7, height: 7)
                        Text(project.name).font(.callout)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ATAK'a Sor").font(.headline)
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                TextField("Bugün ne yapmalıyım?", text: $model.askText)
                    .textFieldStyle(.plain)
                    .onSubmit { router.select(.chat) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))

            Text("Sohbet A7 adımında bağlanıyor. Şu an görev, proje ve notların tamamen çalışıyor.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Bileşenler

struct SummaryTile: View {
    let value: String
    let label: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct SuggestionCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("ATAK Önerisi")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
    }
}

/// Basit sarmalayan yerleşim — etiket/çip listeleri için.
struct FlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(items) { content($0) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { content($0) }
                }
            }
        }
    }
}
