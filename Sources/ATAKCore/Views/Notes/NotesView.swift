import SwiftUI

public struct NotesView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model = NotesViewModel()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 280)
            Divider()
            editorColumn
        }
        .navigationTitle("Notlar")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.addNote() }
                } label: {
                    Label("Yeni not", systemImage: "square.and.pencil")
                }
                .help("Yeni not")
            }
        }
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
            List(selection: $model.selectedID) {
                ForEach(model.notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.displayTitle)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(DateFormat.relativeDay(note.updatedAt))
                            if !note.preview.isEmpty {
                                Text("·")
                                Text(note.preview).lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .overlay {
                if model.notes.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "note.text")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text(model.searchText.isEmpty
                             ? "Henüz not yok."
                             : "Sonuç bulunamadı.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Notlarda ara")
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

                Divider().padding(.horizontal, 20)

                TextEditor(text: bodyBinding)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                HStack {
                    if let draft = model.draft {
                        Text("Güncellendi: \(DateFormat.full(draft.updatedAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Bir not seç veya yeni not oluştur.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
