import Foundation
import Combine

@MainActor
public final class NotesViewModel: ObservableObject {

    @Published public private(set) var notes: [Note] = []
    @Published public var errorMessage: String?
    @Published public var searchText = "" { didSet { reload() } }

    @Published public var selectedID: UUID? { didSet { loadDraft() } }
    @Published public var draft: Note?

    private var service: NoteService?
    private var reloadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    public init() {}

    public func configure(_ environment: AppEnvironment) {
        guard service == nil else { return }
        service = environment.notes
    }

    public func load() async {
        guard let service else { return }
        do {
            notes = try await service.search(searchText)
            if let selectedID, !notes.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    private func loadDraft() {
        guard let selectedID else { draft = nil; return }
        draft = notes.first { $0.id == selectedID }
    }

    public func addNote() async {
        guard let service else { return }
        do {
            let created = try await service.create(title: "", body: "")
            await load()
            selectedID = created.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Yazarken otomatik kaydeder; her tuşta veritabanına gitmemek için geciktirilir.
    public func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    public func save() async {
        guard let draft, let service else { return }
        do {
            try await service.update(draft)
            let keepSelection = draft.id
            await load()
            selectedID = keepSelection
            self.draft = notes.first { $0.id == keepSelection } ?? draft
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ id: UUID) async {
        guard let service else { return }
        saveTask?.cancel()
        do {
            try await service.delete(id)
            if selectedID == id { selectedID = nil }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
