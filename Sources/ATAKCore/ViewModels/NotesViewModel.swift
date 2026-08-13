import Foundation
import Combine

/// Editörün kullanıcıya gösterebileceği otomatik kayıt durumu.
public enum NoteSaveState: Sendable, Equatable {
    case saved
    case saving
    case failed(String)
}

@MainActor
public final class NotesViewModel: ObservableObject {

    @Published public private(set) var notes: [Note] = []
    @Published public var errorMessage: String?
    @Published public var searchText = "" {
        didSet { if searchText != oldValue { reload() } }
    }

    @Published public var selectedID: UUID? {
        didSet { if selectedID != oldValue { loadDraft() } }
    }
    @Published public var draft: Note?
    @Published public private(set) var saveState: NoteSaveState = .saved

    private var service: NoteService?
    private let saveDelay: Duration
    private var reloadTask: Task<Void, Never>?
    private var saveTasks: [UUID: Task<Void, Never>] = [:]

    /// Seçim değişse bile henüz diske gitmemiş son tuşları bellekte tutar.
    private var pendingDrafts: [UUID: Note] = [:]
    private var saveStates: [UUID: NoteSaveState] = [:]
    private var saveVersions: [UUID: UInt64] = [:]
    private var nextSaveVersion: UInt64 = 0

    public init() {
        self.saveDelay = .milliseconds(600)
    }

    /// Testlerin debounce süresini beklemeden gerçek NoteService ile uçtan
    /// uca kayıt davranışını doğrulayabilmesi için iç bağımlılık noktası.
    init(service: NoteService, saveDelay: Duration) {
        self.service = service
        self.saveDelay = saveDelay
    }

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
        guard let selectedID else {
            draft = nil
            saveState = .saved
            return
        }

        // Kullanıcı debounce dolmadan başka nota gidip geri dönerse listedeki
        // eski veritabanı kopyası son tuşların üstüne yazılmamalı.
        draft = pendingDrafts[selectedID] ?? notes.first { $0.id == selectedID }
        saveState = saveStates[selectedID] ?? .saved
    }

    public func addNote() async {
        guard let service else { return }
        do {
            // Aktif arama yeni boş notu hemen görünmez hâle getirmesin.
            if !searchText.isEmpty {
                searchText = ""
                reloadTask?.cancel()
                reloadTask = nil
            }
            let created = try await service.create(title: "", body: "")
            await load()
            selectedID = created.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Yazarken otomatik kaydeder; her tuşta veritabanına gitmemek için geciktirilir.
    public func scheduleSave() {
        guard let snapshot = draft, service != nil else { return }

        // Gecikme sonunda `draft`ı tekrar okumak seçim değişince yanlış notu
        // kaydediyordu. Her tuş serisinin immutable son kopyası taşınıyor.
        saveTasks[snapshot.id]?.cancel()
        let version = stage(snapshot)
        let delay = saveDelay

        // Görev snapshot diske gidene kadar modeli yaşatır. Sekme değiştirilip
        // view bırakıldığında son tuşların sessizce kaybolmasını önler.
        saveTasks[snapshot.id] = Task { [self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await persist(snapshot, version: version)
        }
    }

    public func save() async {
        guard let snapshot = draft, service != nil else { return }
        saveTasks[snapshot.id]?.cancel()
        let version = stage(snapshot)
        await persist(snapshot, version: version)
    }

    private func stage(_ snapshot: Note) -> UInt64 {
        nextSaveVersion += 1
        let version = nextSaveVersion

        pendingDrafts[snapshot.id] = snapshot
        saveVersions[snapshot.id] = version
        saveStates[snapshot.id] = .saving
        if selectedID == snapshot.id { saveState = .saving }

        return version
    }

    private func persist(_ snapshot: Note, version: UInt64) async {
        guard let service else { return }

        do {
            try await service.update(snapshot)

            // Eski bir veritabanı çağrısı devam ederken yeni tuşlar gelmişse
            // onun tamamlanması yeni snapshot'ı "kaydedildi" saymamalı.
            guard saveVersions[snapshot.id] == version else { return }

            let refreshed = try await service.search(searchText)
            guard saveVersions[snapshot.id] == version else { return }

            saveTasks[snapshot.id] = nil
            pendingDrafts[snapshot.id] = nil
            saveStates[snapshot.id] = .saved
            notes = refreshed

            if let selectedID, !notes.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            } else if selectedID == snapshot.id {
                // Yalnız hâlâ aynı not seçiliyse editörü yenile. Başka nota
                // geçmiş kullanıcıyı kayıt bitince eski nota geri sıçratma.
                draft = notes.first { $0.id == snapshot.id } ?? snapshot
                saveState = .saved
            }
        } catch {
            guard saveVersions[snapshot.id] == version else { return }

            let message = error.localizedDescription
            saveTasks[snapshot.id] = nil
            saveStates[snapshot.id] = .failed(message)
            if selectedID == snapshot.id { saveState = .failed(message) }
            errorMessage = message
        }
    }

    public func delete(_ id: UUID) async {
        guard let service else { return }
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        // Devam etmekte olan bir update dönse bile silinen nota ait durumu
        // artık güncel kabul etmesin.
        saveVersions[id] = nil

        do {
            try await service.delete(id)
            pendingDrafts[id] = nil
            saveStates[id] = nil
            if selectedID == id { selectedID = nil }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
