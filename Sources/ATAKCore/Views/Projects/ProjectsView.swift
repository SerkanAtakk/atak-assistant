import SwiftUI

public struct ProjectsView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.atakTheme) private var theme
    @StateObject private var model = ProjectsViewModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(spacing: 0) {
                listColumn
                if model.draft != nil {
                    Rectangle().fill(theme.hairline).frame(width: theme.hairlineWidth)
                    ProjectInspector(model: model)
                        .frame(width: 350)
                }
            }
        }
        .navigationTitle("Projeler")
        .task(id: router.section) {
            guard router.section == .projects else { return }
            model.configure(environment)
            await model.load()
        }
        .alert(
            "Bir sorun oldu",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            ScreenHeader(
                "Projeler",
                subtitle: "Büyük hedefleri görünür, ölçülebilir ilerlemeye dönüştür.",
                eyebrow: "Çalışma alanı",
                systemImage: "square.stack.3d.up.fill"
            )
            Spacer(minLength: 12)
            Text("\(model.projects.filter { $0.status == .active }.count) aktif")
                .font(theme.labelFont(size: 10.5))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.surfaceRaised, in: Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            if model.projects.isEmpty {
                EmptyStateView(
                    systemImage: "square.stack.3d.up",
                    title: "İlk projen için hazır",
                    message: "Bir hedefe isim ver; görevlerini ve ilerlemeni burada birlikte takip edelim."
                )
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.projects) { project in
                        ProjectRow(project: project, progress: model.progress(for: project.id))
                            .tag(project.id)
                            .contextMenu {
                                Button("Sil", role: .destructive) {
                                    Task { await model.delete(project.id) }
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Hairline()
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(theme.accent)
                TextField("Yeni projeye isim ver…", text: $model.newProjectName)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.addProject() } }
                if !model.newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        Task { await model.addProject() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.atakPrimary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(theme.surface.opacity(0.92))
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProjectRow: View {
    @Environment(\.atakTheme) private var theme
    let project: Project
    let progress: ProjectProgress

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(project.color.color)
                .frame(width: 4, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).lineLimit(1)
                HStack(spacing: 8) {
                    if progress.total > 0 {
                        ProgressView(value: progress.fraction)
                            .frame(width: 90)
                            .controlSize(.small)
                        Text("\(progress.done)/\(progress.total)")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        Text("Henüz görev yok").font(.caption).foregroundStyle(theme.textTertiary)
                    }
                    if let deadline = project.deadline {
                        Label(DateFormat.relativeDay(deadline), systemImage: "flag")
                            .font(.caption)
                            .foregroundStyle(deadline < Date() ? theme.danger : theme.textSecondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

struct ProjectInspector: View {
    @Environment(\.atakTheme) private var theme
    @ObservedObject var model: ProjectsViewModel

    var body: some View {
        if let draft = model.draft {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TechLabel("Proje ayrıntısı", color: theme.accent)
                        Spacer()
                        if draft.status == .completed {
                            Label("Tamamlandı", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.success)
                        }
                    }
                    TextField("Proje adı", text: nameBinding)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.medium))
                        .onSubmit { Task { await model.saveDraft() } }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Açıklama").font(.caption).foregroundStyle(theme.textSecondary)
                        TextEditor(text: detailsBinding)
                            .frame(minHeight: 70)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.hairline))
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Durum").font(.caption).foregroundStyle(theme.textSecondary)
                        Picker("", selection: statusBinding) {
                            ForEach(ProjectStatus.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Renk").font(.caption).foregroundStyle(theme.textSecondary)
                        HStack(spacing: 6) {
                            ForEach(ProjectColor.allCases) { option in
                                Button {
                                    model.mutateDraft { $0.color = option }
                                } label: {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 18, height: 18)
                                        .overlay {
                                            Circle()
                                                .strokeBorder(theme.textPrimary, lineWidth: draft.color == option ? 2 : 0)
                                        }
                                        .padding(2)
                                }
                                .buttonStyle(.plain)
                                .help(option.displayName)
                                .accessibilityLabel("Proje rengi: \(option.displayName)")
                                .accessibilityAddTraits(draft.color == option ? .isSelected : [])
                            }
                        }
                    }

                    OptionalDateField(
                        label: "Son tarih",
                        date: deadlineBinding,
                        onChange: { Task { await model.saveDraft() } }
                    )

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Görevler (\(model.projectTasks.count))")
                            .font(.caption).foregroundStyle(theme.textSecondary)
                        if model.projectTasks.isEmpty {
                            Text("Bu projeye bağlı görev yok. Görevler ekranından bir görevi bu projeye atayabilirsin.")
                                .font(.caption)
                                .foregroundStyle(theme.textTertiary)
                        } else {
                            ForEach(model.projectTasks) { task in
                                HStack(spacing: 6) {
                                    Image(systemName: task.status.systemImage)
                                        .foregroundStyle(task.status == .done ? theme.success : theme.textSecondary)
                                        .font(.caption)
                                    Text(task.title)
                                        .font(.caption)
                                        .strikethrough(task.status == .done)
                                        .lineLimit(1)
                                    Spacer()
                                }
                            }
                        }
                    }

                    HStack {
                        Button("Değişiklikleri kaydet") { Task { await model.saveDraft() } }
                            .buttonStyle(.atakPrimary)
                        Spacer()
                        Button("Sil", role: .destructive) {
                            Task { await model.delete(draft.id) }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .background(theme.surface.opacity(0.72))
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.draft?.name ?? "" },
            set: { value in
                guard var draft = model.draft else { return }
                draft.name = value
                model.draft = draft
            }
        )
    }

    private var detailsBinding: Binding<String> {
        Binding(
            get: { model.draft?.details ?? "" },
            set: { value in
                guard var draft = model.draft else { return }
                draft.details = value
                model.draft = draft
            }
        )
    }

    private var statusBinding: Binding<ProjectStatus> {
        Binding(
            get: { model.draft?.status ?? .active },
            set: { value in model.mutateDraft { $0.status = value } }
        )
    }

    private var deadlineBinding: Binding<Date?> {
        Binding(
            get: { model.draft?.deadline },
            set: { value in
                guard var draft = model.draft else { return }
                draft.deadline = value
                model.draft = draft
            }
        )
    }
}
