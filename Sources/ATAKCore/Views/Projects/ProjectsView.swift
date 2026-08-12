import SwiftUI

public struct ProjectsView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model = ProjectsViewModel()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            listColumn
            if model.draft != nil {
                Divider()
                ProjectInspector(model: model)
                    .frame(width: 320)
            }
        }
        .navigationTitle("Projeler")
        .task {
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

    private var listColumn: some View {
        VStack(spacing: 0) {
            if model.projects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("Henüz proje yok.\nBüyük bir hedefi buraya proje olarak ekleyebilirsin.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }

            Divider()
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                TextField("Yeni proje…", text: $model.newProjectName)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.addProject() } }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProjectRow: View {
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
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Görev yok").font(.caption).foregroundStyle(.tertiary)
                    }
                    if let deadline = project.deadline {
                        Label(DateFormat.relativeDay(deadline), systemImage: "flag")
                            .font(.caption)
                            .foregroundStyle(deadline < Date() ? Color.red : .secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

struct ProjectInspector: View {
    @ObservedObject var model: ProjectsViewModel

    var body: some View {
        if let draft = model.draft {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Proje adı", text: nameBinding)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.medium))
                        .onSubmit { Task { await model.saveDraft() } }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Açıklama").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: detailsBinding)
                            .frame(minHeight: 70)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Durum").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: statusBinding) {
                            ForEach(ProjectStatus.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Renk").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(ProjectColor.allCases) { option in
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(.primary, lineWidth: draft.color == option ? 2 : 0)
                                    )
                                    .onTapGesture { model.mutateDraft { $0.color = option } }
                                    .help(option.displayName)
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
                            .font(.caption).foregroundStyle(.secondary)
                        if model.projectTasks.isEmpty {
                            Text("Bu projeye bağlı görev yok. Görevler ekranından bir görevi bu projeye atayabilirsin.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(model.projectTasks) { task in
                                HStack(spacing: 6) {
                                    Image(systemName: task.status.systemImage)
                                        .foregroundStyle(task.status == .done ? Color.accentColor : .secondary)
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
                        Button("Kaydet") { Task { await model.saveDraft() } }
                        Spacer()
                        Button("Sil", role: .destructive) {
                            Task { await model.delete(draft.id) }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .background(.background.secondary)
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
