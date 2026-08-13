import SwiftUI

public struct NotesView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.atakTheme) private var theme
    @StateObject private var model = NotesViewModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(spacing: 0) {
                listColumn
                    .frame(width: 300)
                Rectangle().fill(theme.hairline).frame(width: theme.hairlineWidth)
                editorColumn
            }
        }
        .task(id: router.section) {
            guard router.section == .notes else { return }
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
                "Notlar",
                subtitle: "Fikirlerini kaydet; Türkçe tam metin aramayla saniyeler içinde bul.",
                eyebrow: "Bilgi alanı",
                systemImage: "note.text"
            )
            Spacer(minLength: 12)
            Text("\(model.notes.count) not")
                .font(theme.labelFont(size: 10.5))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.surfaceRaised, in: Capsule())
            Button {
                Task { await model.addNote() }
            } label: {
                Label("Yeni not", systemImage: "square.and.pencil")
            }
            .buttonStyle(.atakPrimary)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("Yeni not (⇧⌘N)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            noteSearchField
            Hairline()
            List(selection: $model.selectedID) {
                ForEach(model.notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.displayTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(DateFormat.relativeDay(note.updatedAt))
                            if !note.preview.isEmpty {
                                Text("·")
                                Text(note.preview).lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 2)
                    .tag(note.id)
                    .contextMenu {
                        Button("Sil", role: .destructive) {
                            Task { await model.delete(note.id) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.notes.isEmpty {
                    EmptyStateView(
                        systemImage: model.searchText.isEmpty ? "note.text" : "magnifyingglass",
                        title: model.searchText.isEmpty ? "İlk notunu oluştur" : "Sonuç bulunamadı",
                        message: model.searchText.isEmpty
                            ? "Toplantı notları, fikirler ve hatırlamak istediklerin burada güvende."
                            : "Başka bir kelime veya daha kısa bir ifade dene.",
                        actionTitle: model.searchText.isEmpty ? "Yeni not" : nil,
                        action: model.searchText.isEmpty ? { Task { await model.addNote() } } : nil
                    )
                }
            }
        }
    }

    private var noteSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.textTertiary)
            TextField("Notlarda ara…", text: $model.searchText)
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
        .padding(.vertical, 9)
        .background(theme.surface.opacity(0.72))
    }

    @ViewBuilder
    private var editorColumn: some View {
        if model.draft != nil {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Başlık", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                Hairline().padding(.horizontal, 20)

                TextEditor(text: bodyBinding)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                HStack {
                    saveStatus
                    Spacer()
                    Button("Sil", role: .destructive) {
                        if let id = model.draft?.id {
                            Task { await model.delete(id) }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(theme.surface.opacity(0.65))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyStateView(
                systemImage: "sidebar.right",
                title: "Bir not seç",
                message: "Listeden bir not seçebilir veya yeni bir sayfa açabilirsin.",
                actionTitle: "Yeni not",
                action: { Task { await model.addNote() } }
            )
        }
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch model.saveState {
        case .saved:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
                Text("Kaydedildi")
                if let draft = model.draft {
                    Text("· \(DateFormat.full(draft.updatedAt))")
                }
            }
            .font(.caption2)
            .foregroundStyle(theme.textTertiary)
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Kaydediliyor…")
            }
            .font(.caption2)
            .foregroundStyle(theme.textSecondary)
        case .failed(let message):
            Label("Kaydedilemedi: \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(theme.danger)
                .lineLimit(1)
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { model.draft?.title ?? "" },
            set: { value in
                guard var draft = model.draft else { return }
                draft.title = value
                model.draft = draft
                model.scheduleSave()
            }
        )
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { model.draft?.body ?? "" },
            set: { value in
                guard var draft = model.draft else { return }
                draft.body = value
                model.draft = draft
                model.scheduleSave()
            }
        )
    }
}
