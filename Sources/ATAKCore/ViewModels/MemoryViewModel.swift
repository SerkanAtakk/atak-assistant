import Foundation
import Combine

/// Hafıza ekranı: ATAK'ın kullanıcı hakkında ne bildiğini gösterir ve
/// silinebilir kılar (MIMARI §4).
///
/// Bu ekranın varlığı bir gizlilik gereği: bir asistanın kullanıcı hakkında
/// sakladığı bilgi, kullanıcının göremediği bir yerde durmamalı.
@MainActor
public final class MemoryViewModel: ObservableObject {

    @Published public private(set) var items: [MemoryItem] = []
    @Published public private(set) var actions: [AssistantAction] = []
    @Published public var searchText = ""
    @Published public var errorMessage: String?
    @Published public private(set) var undoCandidate: AssistantAction?

    /// Yeni kayıt alanları.
    @Published public var draftKey = ""
    @Published public var draftValue = ""

    private weak var environment: AppEnvironment?

    public init() {}

    public func configure(_ environment: AppEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment
    }

    public var isEmpty: Bool { items.isEmpty }

    public func load() async {
        guard let environment, let memory = environment.memory else { return }
        do {
            items = searchText.trimmingCharacters(in: .whitespaces).isEmpty
                ? try await memory.all()
                : try await memory.search(searchText)
            actions = try await environment.actionLog?.recent(limit: 30) ?? []
            undoCandidate = try await environment.undo?.candidate()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func add() async {
        guard let memory = environment?.memory else { return }
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }

        do {
            try await memory.remember(key: key, value: value, source: .userStated)
            draftKey = ""
            draftValue = ""
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func forget(_ item: MemoryItem) async {
        guard let memory = environment?.memory else { return }
        do {
            try await memory.forget(item.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func togglePinned(_ item: MemoryItem) async {
        guard let memory = environment?.memory else { return }
        do {
            try await memory.setPinned(item.id, !item.pinned)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func undoLast() async {
        guard let undo = environment?.undo, let candidate = undoCandidate else { return }
        do {
            try await undo.undo(candidate)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearHistory() async {
        guard let log = environment?.actionLog else { return }
        do {
            try await log.clear()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
