import Foundation
import Testing
@testable import ATAKCore

@Suite("Privacy Mode kalıcılık regresyonları")
struct PrivacyPersistenceRegressionTests {

    @Test("Özel sohbet başlık ve metadata dâhil veritabanına hiç yazılmaz")
    func privateConversationIsMemoryOnly() async throws {
        let context = try await TestDatabase()
        let service = ConversationService(database: context.database)

        let conversation = try await service.create(
            title: "Bu başlık diske girmemeli",
            isPrivate: true
        )
        let userMessage = ChatMessage(
            conversationID: conversation.id,
            role: .user,
            text: "çok özel içerik"
        )
        try await service.append(userMessage, isPrivate: true)
        try await service.updateText(userMessage.id, text: "değişti", isPrivate: true)

        // Dönen değer, ChatViewModel'in bellekte konuşmayı sürdürebilmesi için
        // tüm metadata'yı taşır; fakat iki sohbet tablosu da boş kalır.
        #expect(conversation.title == "Bu başlık diske girmemeli")
        #expect(conversation.isPrivate)
        #expect(try await context.database.query("SELECT * FROM conversation;").isEmpty)
        #expect(try await context.database.query("SELECT * FROM message;").isEmpty)
        #expect(try await service.recent().isEmpty)
    }

    @Test("Privacy Mode sohbeti kaydetmezken araçlar çalışmaya devam eder")
    func privateConversationStillAllowsTools() async throws {
        let context = try await TestDatabase()
        let conversations = ConversationService(database: context.database)
        let tasks = TaskService(database: context.database)
        let toolbox = ATAKToolbox(
            tasks: tasks,
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database)
        )
        let conversation = try await conversations.create(title: "Gizli", isPrivate: true)

        let result = await toolbox.execute(AIToolCall(
            id: "private-tool-call",
            name: "create_task",
            arguments: .object(["title": "Araç hâlâ çalışıyor"])
        ))
        try await conversations.append(
            ChatMessage(
                conversationID: conversation.id,
                role: .tool,
                text: result.content,
                toolCallID: "private-tool-call",
                toolName: "create_task"
            ),
            isPrivate: true
        )

        #expect(!result.isError)
        #expect(try await tasks.list(.open).contains { $0.title == "Araç hâlâ çalışıyor" })
        #expect(try await context.database.query("SELECT * FROM conversation;").isEmpty)
        #expect(try await context.database.query("SELECT * FROM message;").isEmpty)
    }

    @Test("Normal sohbet kalıcılığı değişmeden çalışır")
    func regularConversationStillPersists() async throws {
        let context = try await TestDatabase()
        let service = ConversationService(database: context.database)
        let conversation = try await service.create(title: "Kalıcı")

        try await service.append(
            ChatMessage(conversationID: conversation.id, role: .user, text: "merhaba"),
            isPrivate: false
        )

        #expect(try await service.recent().contains { $0.id == conversation.id })
        #expect(try await service.messages(in: conversation.id).map(\.text) == ["merhaba"])
    }
}

@Suite("Not otomatik kayıt regresyonları")
@MainActor
struct NotesAutosaveRegressionTests {

    @Test("Seçim değişince iki notun da son snapshot'ı kaybolmaz")
    func selectionChangeKeepsLatestSnapshots() async throws {
        let context = try await TestDatabase()
        let service = NoteService(database: context.database)
        let first = try await service.create(title: "Birinci", body: "eski bir")
        let second = try await service.create(title: "İkinci", body: "eski iki")
        let model = NotesViewModel(service: service, saveDelay: .milliseconds(20))

        await model.load()
        model.selectedID = first.id

        var firstDraft = try #require(model.draft)
        firstDraft.body = "ara sürüm"
        model.draft = firstDraft
        model.scheduleSave()

        // Aynı debounce penceresindeki son tuşlar asıl kaydedilecek snapshot.
        firstDraft.body = "birinci son tuşlar"
        model.draft = firstDraft
        model.scheduleSave()
        #expect(model.saveState == .saving)

        model.selectedID = second.id
        var secondDraft = try #require(model.draft)
        secondDraft.body = "ikinci son tuşlar"
        model.draft = secondDraft
        model.scheduleSave()

        // İlk nota debounce dolmadan geri dönmek, listedeki eski kopyayla
        // pending snapshot'ın üstüne yazmamalı.
        model.selectedID = first.id
        #expect(model.draft?.body == "birinci son tuşlar")
        model.selectedID = second.id
        #expect(model.saveState == .saving)

        // Sabit uzun bir bekleme yerine gerçek veritabanı durumunu yokla.
        for _ in 0..<100 {
            let firstBody = try await service.find(first.id)?.body
            let secondBody = try await service.find(second.id)?.body
            if firstBody == "birinci son tuşlar",
               secondBody == "ikinci son tuşlar",
               model.saveState == .saved {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(try await service.find(first.id)?.body == "birinci son tuşlar")
        #expect(try await service.find(second.id)?.body == "ikinci son tuşlar")
        #expect(model.selectedID == second.id, "arka plan kaydı seçimi eski nota döndürmemeli")
        #expect(model.draft?.body == "ikinci son tuşlar")
        #expect(model.saveState == .saved)
    }
}
