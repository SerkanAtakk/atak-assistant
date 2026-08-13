import Testing
import Foundation
@testable import ATAKCore

@Suite("Uzun vadeli hafıza")
struct MemoryServiceTests {

    @Test("Hatırlanan bilgi kaydedilir ve geri okunur")
    func rememberPersists() async throws {
        let context = try await TestDatabase()
        let memory = MemoryService(database: context.database)

        let item = try await memory.remember(
            kind: .routine, key: "spor günleri", value: "salı ve perşembe"
        )

        let stored = try #require(try await memory.find(item.id))
        #expect(stored.key == "spor günleri")
        #expect(stored.value == "salı ve perşembe")
        #expect(stored.kind == .routine)
    }

    /// Hafızanın nasıl değiştiği de bilgidir: eski kayıt silinmez,
    /// "geçersiz kılındı" işaretlenir ve aktif listede görünmez.
    @Test("Aynı konuda yeni bilgi eskisini geçersiz kılar")
    func newValueSupersedesOld() async throws {
        let context = try await TestDatabase()
        let memory = MemoryService(database: context.database)

        try await memory.remember(key: "şehir", value: "Ankara")
        try await memory.remember(key: "şehir", value: "İzmir")

        let active = try await memory.all()
        #expect(active.count == 1)
        #expect(active.first?.value == "İzmir")

        // Eski kayıt tarihî veri olarak duruyor.
        #expect(try await memory.all(includeSuperseded: true).count == 2)
    }

    @Test("Farklı konular birbirini geçersiz kılmaz")
    func differentKeysCoexist() async throws {
        let context = try await TestDatabase()
        let memory = MemoryService(database: context.database)

        try await memory.remember(key: "şehir", value: "İzmir")
        try await memory.remember(key: "meslek", value: "öğrenci")

        #expect(try await memory.all().count == 2)
    }

    /// MIMARI §8: okunan içerikten hafızaya yazmak prompt injection'ın en
    /// kalıcı biçimi olurdu — sahte bir "bilgi" sonsuza kadar sistem
    /// promptunda kalırdı.
    @Test("Okunan içerikten hafızaya yazılamaz")
    func readContentCannotWriteMemory() async throws {
        let context = try await TestDatabase()
        let memory = MemoryService(database: context.database)

        await #expect(throws: ATAKError.self) {
            try await memory.remember(key: "şifre", value: "1234", source: .readContent)
        }
        #expect(try await memory.all().isEmpty)
    }

    @Test("Boş konu veya içerik reddedilir", arguments: [("", "değer"), ("konu", ""), ("  ", "  ")])
    func emptyInputIsRejected(input: (String, String)) async throws {
        let context = try await TestDatabase()
        let memory = MemoryService(database: context.database)

        await #expect(throws: ATAKError.self) {
            try await memory.remember(key: input.0, value: input.1)
        }
    }

    @Test("Türkçe katlamalı arama 'ı' harfini bulur")
    func turkishFoldedSearch() async throws {
        let context = try await TestDatabase()
        let memory = MemoryService(database: context.database)

        try await memory.remember(key: "çalışma saatleri", value: "sabah erken")

        let found = try await memory.search("calisma")
        #expect(found.count == 1)
    }

    @Test("Sistem promptu özeti sabitlenmişleri öne alır ve sınırı aşmaz")
    func digestPrefersPinned() async throws {
        let context = try await TestDatabase()
        let memory = MemoryService(database: context.database)

        for index in 0..<10 {
            try await memory.remember(key: "konu\(index)", value: "değer\(index)")
        }
        let pinned = try await memory.remember(key: "önemli", value: "sabitlenmiş bilgi")
        try await memory.setPinned(pinned.id, true)

        let digest = try await memory.promptDigest(limit: 3)
        let lines = digest.split(separator: "\n")

        #expect(lines.count == 3)
        #expect(digest.contains("sabitlenmiş bilgi"))
    }

    @Test("Hafıza boşken özet boş metin döner")
    func emptyDigest() async throws {
        let context = try await TestDatabase()
        let memory = MemoryService(database: context.database)
        #expect(try await memory.promptDigest().isEmpty)
    }

    @Test("Unutulan kayıt aramada çıkmaz")
    func forgetRemoves() async throws {
        let context = try await TestDatabase()
        let memory = MemoryService(database: context.database)

        let item = try await memory.remember(key: "geçici", value: "silinecek")
        try await memory.forget(item.id)

        #expect(try await memory.all().isEmpty)
        #expect(try await memory.search("geçici").isEmpty)
    }
}

@Suite("Hafızanın sistem promptuna girişi")
struct MemoryPromptTests {

    @Test("Özet varsa sistem promptuna eklenir")
    func digestAppearsInPrompt() {
        let prompt = ATAKPrompt.system(
            toolsEnabled: false,
            memoryDigest: "- spor günleri: salı ve perşembe"
        )
        #expect(prompt.contains("spor günleri"))
        #expect(prompt.contains("hatırladıkların"))
    }

    @Test("Özet boşsa prompt hafıza bölümü içermez")
    func emptyDigestAddsNothing() {
        let prompt = ATAKPrompt.system(toolsEnabled: false, memoryDigest: "")
        #expect(!prompt.contains("hatırladıkların"))
    }
}
