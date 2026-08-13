import Foundation
import Testing
@testable import ATAKCore

// XCTest bu makinede yok (Xcode kurulu değil); swift-testing kullanılıyor.

/// Her test kendi geçici veritabanını alır — testler paralel koşarken
/// birbirini kirletmez.
final class TestDatabase: Sendable {
    let database: Database
    let directory: URL

    init() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "atak-test-\(UUID().uuidString)")
        self.directory = directory
        self.database = try Database(path: directory.appending(path: "atak.db"))
        try await database.migrate()
    }

    /// Test bitince geçici dosyalar silinir; başarısız testte de çalışır.
    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func posixPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
}

// MARK: - Dosya güvenliği

@Suite("Veritabanı dosya güvenliği")
struct DatabaseFileSecurityTests {

    @Test("Klasör 0700, DB/WAL/SHM dosyaları 0600 yapılır")
    func hardensExistingAndCompanionFiles() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appending(path: "atak-permissions-\(UUID().uuidString)")
        let databaseURL = directory.appending(path: "atak.db")
        defer { try? fileManager.removeItem(at: directory) }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        try Data().write(to: databaseURL)
        try fileManager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: databaseURL.path)

        let database = try Database(path: databaseURL)
        try await database.migrate()

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        try #require(fileManager.fileExists(atPath: walURL.path))
        try #require(fileManager.fileExists(atPath: shmURL.path))

        #expect(try posixPermissions(of: directory) == 0o700)
        #expect(try posixPermissions(of: databaseURL) == 0o600)
        #expect(try posixPermissions(of: walURL) == 0o600)
        #expect(try posixPermissions(of: shmURL) == 0o600)

        // SQLite eşlikçi dosyaları daha sonra yeniden oluşturabilir. Her DB
        // erişimi güvenli modu yeniden doğrulamalı ve düzeltebilmelidir.
        try fileManager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: walURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: shmURL.path)
        _ = try await database.healthCheck()

        #expect(try posixPermissions(of: walURL) == 0o600)
        #expect(try posixPermissions(of: shmURL) == 0o600)
    }

    @Test("Dosya güvenliği hazırlama hatası uygulama hata tipine çevrilir")
    func reportsSecurityPreparationFailure() {
        let impossiblePath = URL(fileURLWithPath: "/dev/null/atak-\(UUID().uuidString).db")
        #expect(throws: ATAKError.self) {
            _ = try Database(path: impossiblePath)
        }
    }

    @Test("Bellek içi veritabanı dosya oluşturmadan çalışır")
    func inMemoryDatabaseRemainsInMemory() async throws {
        let database = try Database.inMemory()
        try await database.migrate()
        #expect(try await database.currentSchemaVersion() == Migrator.all.count)
    }
}

// MARK: - Şema

@Suite("Şema ve migrasyon")
struct SchemaTests {

    @Test("Migrasyon şemayı son sürüme taşır")
    func migratesToLatest() async throws {
        let context = try await TestDatabase()
        #expect(try await context.database.currentSchemaVersion() == Migrator.all.count)
        #expect(try await context.database.healthCheck() == "ok")
    }

    @Test("Migrasyon tekrar çalıştırılabilir")
    func migrationIsIdempotent() async throws {
        let context = try await TestDatabase()
        try await context.database.migrate()
        try await context.database.migrate()
        #expect(try await context.database.currentSchemaVersion() == Migrator.all.count)
    }

    /// Gerçek yükseltme yolu: kullanıcının diskindeki veritabanı v1'de kaldı.
    @Test("v1 veritabanı v2'ye yükselir ve mevcut veri korunur")
    func upgradesFromV1WithoutDataLoss() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "atak-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try Database(path: directory.appending(path: "atak.db"))

        // 1) Yalnızca v1 şemasıyla başla.
        try await database.migrate(upTo: 1)
        #expect(try await database.currentSchemaVersion() == 1)

        // 2) v1 şemasına veri yaz (yeni sütunlar henüz yok).
        let conversationID = UUID()
        try await database.run(
            """
            INSERT INTO conversation (id, title, mode, started_at, is_private, archived)
            VALUES (?, ?, 'general', ?, 0, 0);
            """,
            [.uuid(conversationID), .text("Eski sohbet"), .date(Date())]
        )
        try await database.run(
            """
            INSERT INTO message (id, conversation_id, role, content, created_at)
            VALUES (?, ?, 'user', ?, ?);
            """,
            [.uuid(UUID()), .uuid(conversationID), .text("eski mesaj"), .date(Date())]
        )

        // 3) Yükselt.
        try await database.migrate()
        #expect(try await database.currentSchemaVersion() == Migrator.all.count)

        // 4) Eski veri yerinde ve okunabilir mi?
        let service = ConversationService(database: database)
        let existing = try await service.messages(in: conversationID)
        #expect(existing.count == 1)
        #expect(existing.first?.text == "eski mesaj")
        #expect(existing.first?.toolCalls.isEmpty == true)

        // 5) Yeni sütunlar gerçekten kullanılabiliyor mu?
        try await service.append(
            ChatMessage(
                conversationID: conversationID,
                role: .assistant,
                text: "yeni",
                toolCalls: [AIToolCall(id: "1", name: "create_task", arguments: .object(["title": "x"]))]
            ),
            isPrivate: false
        )
        let afterUpgrade = try await service.messages(in: conversationID)
        #expect(afterUpgrade.count == 2)
        #expect(afterUpgrade.last?.toolCalls.first?.name == "create_task")
    }
}

// MARK: - Sohbet kalıcılığı

@Suite("Sohbet kalıcılığı")
struct ConversationTests {

    @Test("Privacy Mode'da mesaj diske yazılmaz")
    func privateModeSkipsDisk() async throws {
        let context = try await TestDatabase()
        let service = ConversationService(database: context.database)

        let conversation = try await service.create(title: "Gizli", isPrivate: true)
        try await service.append(
            ChatMessage(conversationID: conversation.id, role: .user, text: "gizli mesaj"),
            isPrivate: true
        )

        #expect(try await service.messages(in: conversation.id).isEmpty)
    }

    @Test("Araç çağrıları kaydedilip geri okunur")
    func toolCallsRoundTrip() async throws {
        let context = try await TestDatabase()
        let service = ConversationService(database: context.database)
        let conversation = try await service.create()

        let call = AIToolCall(
            id: "call-1", name: "create_task",
            arguments: .object(["title": "Spor", "priority": "high"])
        )
        try await service.append(
            ChatMessage(conversationID: conversation.id, role: .assistant, text: "Ekledim", toolCalls: [call]),
            isPrivate: false
        )

        let saved = try await service.messages(in: conversation.id).first
        #expect(saved?.toolCalls.count == 1)
        #expect(saved?.toolCalls.first?.arguments["title"]?.stringValue == "Spor")
    }

    @Test("Sohbet silinince mesajları da silinir")
    func deleteCascades() async throws {
        let context = try await TestDatabase()
        let service = ConversationService(database: context.database)
        let conversation = try await service.create()

        try await service.append(
            ChatMessage(conversationID: conversation.id, role: .user, text: "selam"),
            isPrivate: false
        )
        try await service.delete(conversation.id)

        #expect(try await service.messages(in: conversation.id).isEmpty)
    }

    @Test("Araç mesajları sohbet dökümünde gösterilmez")
    func toolMessagesAreHidden() {
        // Araç sonuçları kullanıcıya balon olarak değil, rozet olarak görünür.
        let id = UUID()
        #expect(!ChatMessage(conversationID: id, role: .tool, text: "sonuç").isVisibleInTranscript)
        #expect(ChatMessage(conversationID: id, role: .user, text: "selam").isVisibleInTranscript)
        #expect(!ChatMessage(conversationID: id, role: .assistant, text: "").isVisibleInTranscript)
    }
}

// MARK: - Görevler

@Suite("Görevler")
struct TaskTests {

    @Test("Görev oluşturulur ve etiketleriyle geri okunur")
    func createAndFetch() async throws {
        let context = try await TestDatabase()
        let service = TaskService(database: context.database)

        let created = try await service.create(
            title: "Sunumu bitir",
            priority: .high,
            dueAt: Date().addingTimeInterval(3600),
            estimatedMinutes: 90,
            tags: ["okul", "sunum"]
        )

        let fetched = try await service.find(created.id)
        #expect(fetched?.title == "Sunumu bitir")
        #expect(fetched?.priority == .high)
        #expect(fetched?.estimatedMinutes == 90)
        #expect(fetched?.tags == ["okul", "sunum"])
    }

    @Test("Boş başlık reddedilir")
    func rejectsEmptyTitle() async throws {
        let context = try await TestDatabase()
        let service = TaskService(database: context.database)

        await #expect(throws: ATAKError.self) {
            _ = try await service.create(title: "   ")
        }
    }

    @Test("Tamamlama tarihi tutarlı kalır")
    func completionTogglesTimestamp() async throws {
        let context = try await TestDatabase()
        let service = TaskService(database: context.database)

        let task = try await service.create(title: "Spor")

        try await service.setCompleted(task.id, true)
        let done = try await service.find(task.id)
        #expect(done?.status == .done)
        #expect(done?.completedAt != nil)

        try await service.setCompleted(task.id, false)
        let reopened = try await service.find(task.id)
        #expect(reopened?.status == .todo)
        #expect(reopened?.completedAt == nil, "geri alınan görevde tamamlanma tarihi kalmamalı")
    }

    @Test("Gecikmiş filtresi tamamlanmışları dışarıda bırakır")
    func overdueExcludesCompleted() async throws {
        let context = try await TestDatabase()
        let service = TaskService(database: context.database)

        let past = Date().addingTimeInterval(-86_400)
        let stillOpen = try await service.create(title: "Gecikmiş", dueAt: past)
        let finished = try await service.create(title: "Bitmiş ama gecikmişti", dueAt: past)
        try await service.setCompleted(finished.id, true)

        let overdue = try await service.list(.overdue)
        #expect(overdue.contains { $0.id == stillOpen.id })
        #expect(!overdue.contains { $0.id == finished.id })
    }

    @Test("Güncellemede etiketler eklenmez, değiştirilir")
    func tagsAreReplaced() async throws {
        let context = try await TestDatabase()
        let service = TaskService(database: context.database)

        var task = try await service.create(title: "Etiket testi", tags: ["a", "b"])
        task.tags = ["c"]
        try await service.update(task)

        #expect(try await service.find(task.id)?.tags == ["c"])
    }

    @Test("Görev silinince alt görevleri de silinir")
    func deleteCascadesToSubtasks() async throws {
        let context = try await TestDatabase()
        let service = TaskService(database: context.database)

        let parent = try await service.create(title: "Ana görev")
        let child = try await service.create(title: "Alt görev", parentTaskID: parent.id)

        try await service.delete(parent.id)
        #expect(try await service.find(child.id) == nil)
    }

    /// Tarihler "şimdi ± süre" yerine GÜNE sabitleniyor.
    ///
    /// Önceki hâli `now + 30dk` kullanıyordu; test gece yarısına 30 dakikadan
    /// az kala çalışınca o tarih yarına düşüyor ve sayım değişiyordu. Testin
    /// çalıştığı saate göre sonuç değiştirmesi kabul edilemez.
    @Test("Sayımlar açık/bugün/gecikmiş ayrımını doğru yapar")
    func countsAreAccurate() async throws {
        let context = try await TestDatabase()
        let service = TaskService(database: context.database)

        let bounds = TaskService.todayBounds()
        let noonToday = bounds.start.addingTimeInterval(12 * 3600)
        let twoDaysAgo = bounds.start.addingTimeInterval(-2 * 86_400)
        let tomorrow = bounds.start.addingTimeInterval(26 * 3600)

        _ = try await service.create(title: "bugün öğlen", dueAt: noonToday)
        _ = try await service.create(title: "iki gün önce", dueAt: twoDaysAgo)
        _ = try await service.create(title: "yarın", dueAt: tomorrow)
        _ = try await service.create(title: "tarihsiz")
        let done = try await service.create(title: "bitti", dueAt: twoDaysAgo)
        try await service.setCompleted(done.id, true)

        let counts = try await service.counts()
        #expect(counts.open == 4)
        #expect(counts.dueToday == 1, "yalnız bugüne düşen görev sayılmalı")
        // "bugün öğlen" günün saatine göre gecikmiş olabilir; bu yüzden
        // gecikmişlerde yalnız kesin olan asgari sayı doğrulanıyor.
        #expect(counts.overdue >= 1)
    }

    @Test("Aciliyet skoru gecikmiş işi öne alır")
    func urgencyPrefersOverdue() {
        let overdue = TaskItem(title: "gecikmiş", priority: .normal, dueAt: Date().addingTimeInterval(-3600))
        let later = TaskItem(title: "sonra", priority: .normal, dueAt: Date().addingTimeInterval(86_400 * 10))
        #expect(overdue.urgencyScore > later.urgencyScore)
    }
}

// MARK: - Projeler

@Suite("Projeler")
struct ProjectTests {

    @Test("Proje silinince görevleri kaybolmaz")
    func deleteKeepsTasks() async throws {
        let context = try await TestDatabase()
        let projects = ProjectService(database: context.database)
        let tasks = TaskService(database: context.database)

        let project = try await projects.create(name: "Mobil uygulama")
        let task = try await tasks.create(title: "Araştırma", projectID: project.id)

        try await projects.delete(project.id)

        let survivor = try await tasks.find(task.id)
        #expect(survivor != nil, "proje silinince görev kaybolmamalı")
        #expect(survivor?.projectID == nil)
    }

    @Test("İlerleme sayımı doğru")
    func progressCounts() async throws {
        let context = try await TestDatabase()
        let projects = ProjectService(database: context.database)
        let tasks = TaskService(database: context.database)

        let project = try await projects.create(name: "Test projesi")
        let first = try await tasks.create(title: "1", projectID: project.id)
        _ = try await tasks.create(title: "2", projectID: project.id)
        try await tasks.setCompleted(first.id, true)

        let progress = try await projects.progressByProject()[project.id]
        #expect(progress?.total == 2)
        #expect(progress?.done == 1)
        #expect(progress?.fraction == 0.5)
    }

    @Test("Boş proje adı reddedilir")
    func rejectsEmptyName() async throws {
        let context = try await TestDatabase()
        let projects = ProjectService(database: context.database)

        await #expect(throws: ATAKError.self) {
            _ = try await projects.create(name: "  ")
        }
    }
}

// MARK: - Notlar & FTS5

@Suite("Notlar ve tam metin arama")
struct NoteTests {

    @Test("FTS5 araması eşleşen notu bulur")
    func fullTextSearch() async throws {
        let context = try await TestDatabase()
        let service = NoteService(database: context.database)

        let target = try await service.create(title: "Toplantı notu", body: "Bütçe konuşuldu")
        _ = try await service.create(title: "Alışveriş", body: "Süt ekmek")

        let results = try await service.search("bütçe")
        #expect(results.count == 1)
        #expect(results.first?.id == target.id)
    }

    @Test(
        "Türkçe harfler aramada ASCII karşılığıyla eşleşir",
        arguments: ["calisma", "çalışma", "ÇALIŞMA", "calışma", "Calisma", "calis"]
    )
    func turkishFoldedSearch(query: String) async throws {
        let context = try await TestDatabase()
        let service = NoteService(database: context.database)

        let note = try await service.create(title: "Çalışma planı", body: "Yarın için")
        #expect(try await service.search(query).contains { $0.id == note.id })
    }

    @Test("Noktasız ı ve İ her iki yönde eşleşir")
    func dotlessIMatching() async throws {
        let context = try await TestDatabase()
        let service = NoteService(database: context.database)

        let note = try await service.create(title: "İstanbul", body: "Kırmızı ışık")

        #expect(try await service.search("istanbul").contains { $0.id == note.id })
        #expect(try await service.search("İstanbul").contains { $0.id == note.id })
        #expect(try await service.search("kirmizi").contains { $0.id == note.id })
        #expect(try await service.search("ısık").contains { $0.id == note.id })
    }

    @Test("Not güncellenince arama indeksi de güncellenir")
    func updateRefreshesIndex() async throws {
        let context = try await TestDatabase()
        let service = NoteService(database: context.database)

        var note = try await service.create(title: "İlk", body: "elma")
        note.body = "armut"
        try await service.update(note)

        #expect(try await service.search("elma").isEmpty, "eski içerik indekste kalmamalı")
        #expect(!(try await service.search("armut").isEmpty))
    }

    @Test("Not silinince arama indeksinden düşer")
    func deleteRemovesFromIndex() async throws {
        let context = try await TestDatabase()
        let service = NoteService(database: context.database)

        let note = try await service.create(title: "Silinecek", body: "gizli kelime")
        try await service.delete(note.id)

        #expect(try await service.search("gizli").isEmpty)
    }

    @Test("Bozuk arama girdisi çökmeye yol açmaz", arguments: ["\"", "a\"b", "*", "()", "AND OR", "   ", "-", "NEAR("])
    func malformedQueryIsSafe(input: String) async throws {
        let context = try await TestDatabase()
        let service = NoteService(database: context.database)
        _ = try await service.create(title: "Normal", body: "içerik")

        _ = try await service.search(input)
    }

    @Test("Boş arama tüm notları döndürür")
    func emptySearchReturnsAll() async throws {
        let context = try await TestDatabase()
        let service = NoteService(database: context.database)

        _ = try await service.create(title: "bir", body: "")
        _ = try await service.create(title: "iki", body: "")

        #expect(try await service.search("").count == 2)
    }
}

// MARK: - Türkçe metin katlama

@Suite("Türkçe metin katlama")
struct TurkishTextTests {

    @Test(
        "Türkçe harfler ASCII karşılığına düşer",
        arguments: [
            ("Çalışma", "calisma"),
            ("İSTANBUL", "istanbul"),
            ("ışık", "isik"),
            ("Ğğ Üü Öö Şş", "gg uu oo ss"),
            ("ATAK", "atak"),
            ("kâğıt", "kagit"),
        ]
    )
    func folding(input: String, expected: String) {
        #expect(TurkishText.fold(input) == expected)
    }

    @Test("Katlama büyük/küçük harfe göre değişmez")
    func foldingIsCaseStable() {
        #expect(TurkishText.fold("Çalışma") == TurkishText.fold("ÇALIŞMA"))
        #expect(TurkishText.fold("İstanbul") == TurkishText.fold("istanbul"))
        // Türkçe'de I'nın küçüğü ı'dır; ikisi de aynı arama anahtarına düşmeli.
        #expect(TurkishText.fold("IŞIK") == TurkishText.fold("ışık"))
    }

    @Test("Boş ve noktalama girdileri güvenli")
    func handlesEdgeCases() {
        #expect(TurkishText.fold("") == "")
        #expect(TurkishText.fold("123 !?") == "123 !?")
        #expect(TurkishText.searchText("", "") == "")
    }
}

// MARK: - İşlem bütünlüğü

@Suite("İşlem bütünlüğü")
struct TransactionTests {

    @Test("Hata alan işlem tamamen geri alınır")
    func rollsBackOnFailure() async throws {
        let context = try await TestDatabase()
        let id = UUID()

        await #expect(throws: (any Error).self) {
            try await context.database.transaction([
                SQLStatement(
                    """
                    INSERT INTO project (id, name, description, status, color, created_at)
                    VALUES (?, ?, '', 'active', 'blue', ?);
                    """,
                    [.uuid(id), .text("Yarım kalacak"), .date(Date())]
                ),
                // Aynı birincil anahtar → ikinci ifade patlar.
                SQLStatement(
                    """
                    INSERT INTO project (id, name, description, status, color, created_at)
                    VALUES (?, ?, '', 'active', 'blue', ?);
                    """,
                    [.uuid(id), .text("Çakışan kimlik"), .date(Date())]
                ),
            ])
        }

        let rows = try await context.database.query("SELECT * FROM project WHERE id = ?;", [.uuid(id)])
        #expect(rows.isEmpty, "hata sonrası ilk ekleme de geri alınmalıydı")
    }
}
