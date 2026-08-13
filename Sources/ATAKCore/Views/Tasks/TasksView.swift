import SwiftUI

public struct TasksView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.atakTheme) private var theme
    @StateObject private var model = TasksViewModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(spacing: 0) {
                listColumn
                if model.draft != nil {
                    Rectangle().fill(theme.hairline).frame(width: theme.hairlineWidth)
                    TaskInspector(model: model)
                        .frame(width: 330)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .task(id: router.section) {
            guard router.section == .tasks else { return }
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
                "Görevler",
                subtitle: "Günün işlerini tek yerde planla ve ilerlemeyi takip et.",
                eyebrow: "Çalışma alanı",
                systemImage: "checklist"
            )
            Spacer(minLength: 12)
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text("\(model.tasks.count) kayıt")
                    .font(theme.labelFont(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.surfaceRaised, in: Capsule())
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Liste

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Filtre", selection: $model.filter) {
                    ForEach(TaskListFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)
                Spacer(minLength: 0)
                compactSearchField
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(theme.surface.opacity(0.45))
            Hairline()

            List(selection: $model.selectedID) {
                ForEach(model.tasks) { task in
                    TaskRow(task: task, model: model)
                        .tag(task.id)
                        .contextMenu {
                            Button(task.status == .done ? "Geri al" : "Tamamlandı") {
                                Task { await model.toggleCompleted(task) }
                            }
                            Divider()
                            Button("Sil", role: .destructive) {
                                Task { await model.delete(task.id) }
                            }
                        }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.tasks.isEmpty && !model.isLoading {
                    emptyState
                }
            }

            Hairline()
            addBar
        }
        .frame(maxWidth: .infinity)
    }

    private var compactSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.textTertiary)
            TextField("Görevlerde ara…", text: $model.searchText)
                .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textTertiary)
                .help("Aramayı temizle")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 220)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: theme.cornerRadiusTight))
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadiusTight)
                .strokeBorder(theme.hairline, lineWidth: theme.hairlineWidth)
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: model.searchText.isEmpty ? "checklist" : "magnifyingglass",
            title: model.searchText.isEmpty ? "Bu görünüm tertemiz" : "Eşleşen görev yok",
            message: model.emptyStateMessage
        )
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .foregroundStyle(theme.accent)
            TextField("Hızlı görev ekle…", text: $model.newTaskTitle)
                .textFieldStyle(.plain)
                .onSubmit { Task { await model.addTask() } }
            if !model.newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    Task { await model.addTask() }
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
}

// MARK: - Satır

struct TaskRow: View {
    @Environment(\.atakTheme) private var theme
    let task: TaskItem
    @ObservedObject var model: TasksViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                Task { await model.toggleCompleted(task) }
            } label: {
                Image(systemName: task.status.systemImage)
                    .foregroundStyle(task.status == .done ? theme.success : theme.textTertiary)
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .help(task.status == .done ? "Geri al" : "Tamamlandı olarak işaretle")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .strikethrough(task.status == .done, color: .secondary)
                    .foregroundStyle(task.status == .done ? theme.textSecondary : theme.textPrimary)
                    .lineLimit(2)

                if hasMetadata {
                    HStack(spacing: 8) {
                        if let due = task.dueAt {
                            Label(DateFormat.relativeDay(due), systemImage: "calendar")
                                .foregroundStyle(task.isOverdue ? theme.danger : theme.textSecondary)
                        }
                        if let projectName = model.projectName(for: task.projectID) {
                            Label(projectName, systemImage: "square.stack.3d.up")
                                .foregroundStyle(theme.textSecondary)
                        }
                        if let minutes = task.estimatedMinutes {
                            Label(DateFormat.duration(minutes: minutes), systemImage: "clock")
                                .foregroundStyle(theme.textSecondary)
                        }
                        ForEach(task.tags, id: \.self) { tag in
                            Text("#\(tag)").foregroundStyle(theme.textTertiary)
                        }
                    }
                    .font(.caption)
                }
            }

            Spacer(minLength: 6)

            if task.priority != .normal {
                Image(systemName: task.priority.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(task.priority == .urgent ? theme.danger : theme.warning)
                    .help("Öncelik: \(task.priority.displayName)")
            }
        }
        .padding(.vertical, 3)
    }

    private var hasMetadata: Bool {
        task.dueAt != nil
            || task.projectID != nil
            || task.estimatedMinutes != nil
            || !task.tags.isEmpty
    }
}

// MARK: - Ayrıntı paneli

struct TaskInspector: View {
    @Environment(\.atakTheme) private var theme
    @ObservedObject var model: TasksViewModel

    var body: some View {
        if let draft = model.draft {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TechLabel("Görev ayrıntısı", color: theme.accent)
                        Spacer()
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(theme.textTertiary)
                    }
                    TextField("Başlık", text: titleBinding, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.medium))
                        .onSubmit { Task { await model.saveDraft() } }

                    field("Durum") {
                        Picker("", selection: statusBinding) {
                            ForEach(TaskStatus.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                    }

                    field("Öncelik") {
                        Picker("", selection: priorityBinding) {
                            ForEach(TaskPriority.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                    }

                    field("Proje") {
                        Picker("", selection: projectBinding) {
                            Text("Yok").tag(UUID?.none)
                            ForEach(model.projects) { project in
                                Text(project.name).tag(UUID?.some(project.id))
                            }
                        }
                        .labelsHidden()
                    }

                    OptionalDateField(
                        label: "Son tarih",
                        date: dueBinding,
                        onChange: { Task { await model.saveDraft() } }
                    )

                    field("Tahmini süre") {
                        HStack {
                            TextField("—", text: estimateBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .onSubmit { Task { await model.saveDraft() } }
                            Text("dakika").foregroundStyle(.secondary).font(.caption)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notlar").font(.caption).foregroundStyle(theme.textSecondary)
                        TextEditor(text: notesBinding)
                            .font(.body)
                            .frame(minHeight: 90)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(theme.hairline)
                            )
                    }

                    HStack {
                        Button("Değişiklikleri kaydet") { Task { await model.saveDraft() } }
                            .buttonStyle(.atakPrimary)
                            .keyboardShortcut("s", modifiers: .command)
                        Spacer()
                        Button("Sil", role: .destructive) {
                            Task { await model.delete(draft.id) }
                        }
                    }
                    .padding(.top, 4)

                    Text("Oluşturuldu · \(DateFormat.full(draft.createdAt))")
                        .font(.caption2)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(16)
            }
            .background(theme.surface.opacity(0.72))
        }
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(theme.textSecondary)
            content()
        }
    }

    // MARK: Bağlamalar

    private var titleBinding: Binding<String> {
        Binding(
            get: { model.draft?.title ?? "" },
            set: { value in
                guard var draft = model.draft else { return }
                draft.title = value
                model.draft = draft
            }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { model.draft?.notes ?? "" },
            set: { value in
                guard var draft = model.draft else { return }
                draft.notes = value
                model.draft = draft
            }
        )
    }

    private var statusBinding: Binding<TaskStatus> {
        Binding(
            get: { model.draft?.status ?? .todo },
            set: { value in model.mutateDraft { $0.status = value } }
        )
    }

    private var priorityBinding: Binding<TaskPriority> {
        Binding(
            get: { model.draft?.priority ?? .normal },
            set: { value in model.mutateDraft { $0.priority = value } }
        )
    }

    private var projectBinding: Binding<UUID?> {
        Binding(
            get: { model.draft?.projectID },
            set: { value in model.mutateDraft { $0.projectID = value } }
        )
    }

    private var dueBinding: Binding<Date?> {
        Binding(
            get: { model.draft?.dueAt },
            set: { value in
                guard var draft = model.draft else { return }
                draft.dueAt = value
                model.draft = draft
            }
        )
    }

    private var estimateBinding: Binding<String> {
        Binding(
            get: { model.draft?.estimatedMinutes.map(String.init) ?? "" },
            set: { value in
                guard var draft = model.draft else { return }
                draft.estimatedMinutes = Int(value.filter(\.isNumber))
                model.draft = draft
            }
        )
    }
}

/// Açılıp kapanabilen tarih alanı — `nil` "tarih yok" demektir.
struct OptionalDateField: View {
    let label: String
    @Binding var date: Date?
    var onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if date != nil {
                DatePicker("", selection: unwrappedBinding, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { date != nil },
            set: { isOn in
                date = isOn ? (date ?? defaultDate()) : nil
                onChange()
            }
        )
    }

    private var unwrappedBinding: Binding<Date> {
        Binding(
            get: { date ?? defaultDate() },
            set: { date = $0; onChange() }
        )
    }

    /// Yeni tarih açıldığında bugünün sonuna ayarlanır — 00:00 istisnasız yanlış olurdu.
    private func defaultDate() -> Date {
        let calendar = Calendar.current
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    }
}
