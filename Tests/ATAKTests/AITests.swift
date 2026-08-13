import Foundation
import Testing
@testable import ATAKCore

// MARK: - SSE ayrıştırıcı

@Suite("SSE ayrıştırıcı")
struct SSETests {

    /// Satır dizisini uçtan uca ayrıştırıp yayınlanan yükleri döndürür.
    private func run(_ lines: [String]) -> [String] {
        var parser = SSE.Parser()
        var output: [String] = []

        for line in lines {
            switch parser.consume(line: line) {
            case .none:
                continue
            case .payload(let payload):
                output.append(payload)
            case .done:
                if let remainder = parser.flush() { output.append(remainder) }
                return output
            }
        }
        if let remainder = parser.flush() { output.append(remainder) }
        return output
    }

    @Test("Basit data satırları ayrıştırılır")
    func simpleEvents() {
        let output = run([
            "data: {\"a\":1}", "",
            "data: {\"a\":2}", "",
        ])
        #expect(output == ["{\"a\":1}", "{\"a\":2}"])
    }

    @Test("Boşluksuz 'data:' biçimi de kabul edilir")
    func noSpaceAfterColon() {
        #expect(run(["data:{\"x\":true}", ""]) == ["{\"x\":true}"])
    }

    @Test("Yorum ve heartbeat satırları atlanır")
    func ignoresComments() {
        let output = run([": ping", "data: {\"a\":1}", ": keep-alive", ""])
        #expect(output == ["{\"a\":1}"])
    }

    @Test("Çok satırlı data blokları birleştirilir")
    func multilineData() {
        #expect(run(["data: {\"a\":", "data: 1}", ""]) == ["{\"a\":\n1}"])
    }

    @Test("[DONE] akışı bitirir ve sonrasını okumaz")
    func stopsOnDone() {
        let output = run([
            "data: {\"a\":1}", "",
            "data: [DONE]",
            "data: {\"asla\":\"okunmamalı\"}", "",
        ])
        #expect(output == ["{\"a\":1}"])
    }

    @Test("Sondaki boş satır gelmese de veri kaybolmaz")
    func flushesTrailingPayload() {
        #expect(run(["data: {\"son\":1}"]) == ["{\"son\":1}"])
    }

    @Test("İlgisiz alanlar (event:, id:) yok sayılır")
    func ignoresOtherFields() {
        let output = run(["event: message_start", "id: 42", "data: {\"a\":1}", ""])
        #expect(output == ["{\"a\":1}"])
    }

    /// Gemini olaylar arasında boş satır göndermiyor. Yalnız boş satırda
    /// yayınlayan bir ayrıştırıcı iki JSON'u birleştirip bozar ve yanıt
    /// sessizce kaybolur — 12 Ağu 2026'da yaşanan hata tam olarak buydu.
    @Test("Boş satır olmadan arka arkaya gelen data satırları ayrı ayrılır")
    func separatesAdjacentDataLinesWithoutBlankLine() {
        let output = run([
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Merhaba!\"}]}}]}",
            "data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}",
        ])
        #expect(output.count == 2)
        #expect(output[0].contains("Merhaba!"))
        #expect(output[1].contains("STOP"))
    }

    @Test("Çok satırlı JSON hâlâ doğru birleştirilir")
    func stillJoinsGenuineMultilinePayloads() {
        // Spesifikasyona uyan sağlayıcılar JSON'u satırlara bölebiliyor;
        // tampon geçerli JSON olmadığı sürece birleştirme sürmeli.
        let output = run(["data: {\"a\":", "data: 1}", ""])
        #expect(output == ["{\"a\":\n1}"])
    }
}

// MARK: - Gerçek Gemini yanıtı

@Suite("Gerçek Gemini akışı")
struct GeminiRealStreamTests {

    /// Google'dan gerçekten dönen iki olay (12 Ağu 2026'da kaydedildi).
    private static let recordedLines = [
        #"data: {"candidates": [{"content": {"parts": [{"text": "Merhaba!"}],"role": "model"},"index": 0}],"usageMetadata": {"promptTokenCount": 10,"candidatesTokenCount": 2,"totalTokenCount": 162,"thoughtsTokenCount": 150},"modelVersion": "gemini-3.6-flash"}"#,
        #"data: {"candidates": [{"content": {"parts": [{"text": "","thoughtSignature": "Eu4FCusFARFNMg"}],"role": "model"},"finishReason": "STOP","index": 0}],"usageMetadata": {"promptTokenCount": 10,"candidatesTokenCount": 2,"totalTokenCount": 162,"thoughtsTokenCount": 150},"modelVersion": "gemini-3.6-flash"}"#,
    ]

    private func parse(_ lines: [String]) -> [JSONValue] {
        var parser = SSE.Parser()
        var payloads: [String] = []
        for line in lines {
            if case .payload(let payload) = parser.consume(line: line) { payloads.append(payload) }
        }
        if let remainder = parser.flush() { payloads.append(remainder) }
        return payloads.compactMap { try? JSONValue.decode($0) }
    }

    @Test("Kaydedilmiş yanıttan metin çıkarılabiliyor")
    func extractsTextFromRecordedResponse() {
        let events = parse(Self.recordedLines)
        #expect(events.count == 2)

        var outcome = GeminiProvider.Outcome()
        var text = ""

        for event in events {
            outcome.absorbUsage(event["usageMetadata"])
            guard let candidate = event["candidates"]?[0] else { continue }
            for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
                if part["thought"]?.boolValue == true { outcome.sawThoughtPart = true; continue }
                if let chunk = part["text"]?.stringValue, !chunk.isEmpty {
                    outcome.sawText = true
                    text += chunk
                }
            }
            if let reason = candidate["finishReason"]?.stringValue { outcome.finishReason = reason }
        }

        #expect(text == "Merhaba!")
        #expect(outcome.finishReason == "STOP")
        #expect(outcome.thoughtsTokens == 150)
        // En önemlisi: artık "boş yanıt" teşhisi üretilmiyor.
        #expect(outcome.emptyResponseDiagnosis(maxTokens: 8192) == nil)
    }

    @Test("thoughtSignature taşıyan boş metin parçası sohbete sızmıyor")
    func emptyThoughtSignaturePartProducesNoText() {
        let events = parse([Self.recordedLines[1]])
        let parts = events[0]["candidates"]?[0]?["content"]?["parts"]?.arrayValue ?? []
        #expect(parts[0]["text"]?.stringValue == "")
        #expect(parts[0]["thoughtSignature"] != nil)
    }
}

// MARK: - JSONValue

@Suite("JSONValue")
struct JSONValueTests {

    @Test("İç içe erişim çalışır")
    func nestedAccess() throws {
        let json = try JSONValue.decode("""
        {"candidates":[{"content":{"parts":[{"text":"merhaba"}]}}]}
        """)
        #expect(json["candidates"]?[0]?["content"]?["parts"]?[0]?["text"]?.stringValue == "merhaba")
    }

    @Test("Eksik yol nil döner, çökmez")
    func missingPath() throws {
        let json = try JSONValue.decode("{\"a\":1}")
        #expect(json["yok"]?["daha"]?[3]?.stringValue == nil)
    }

    @Test("Gidiş-dönüş kodlama bozulmaz")
    func roundTrip() throws {
        let original: JSONValue = .object([
            "s": "metin", "n": 42, "b": true, "arr": .array([1, 2]), "nil": .null,
        ])
        #expect(try JSONValue.decode(original.encodedData()) == original)
    }

    @Test("Türkçe karakter ve eğik çizgi korunur")
    func preservesUnicode() throws {
        let value: JSONValue = .string("Çalışma/planı ığüşöç")
        #expect(try JSONValue.decode(value.encodedData()).stringValue == "Çalışma/planı ığüşöç")
    }
}

// MARK: - Gemini mesaj eşlemesi

@Suite("Gemini mesaj eşlemesi")
struct GeminiMappingTests {

    @Test("Roller Gemini karşılıklarına çevrilir")
    func rolesAreMapped() {
        let contents = GeminiProvider.contents(from: [
            .user("selam"),
            .assistant("merhaba"),
        ])
        #expect(contents[0]["role"]?.stringValue == "user")
        #expect(contents[1]["role"]?.stringValue == "model")
    }

    @Test("Sistem mesajı contents'e girmez")
    func systemIsExcluded() {
        // systemInstruction alanında ayrıca gönderiliyor; burada tekrarlanmamalı.
        let contents = GeminiProvider.contents(from: [
            AIMessage(role: .system, text: "sistem"),
            .user("selam"),
        ])
        #expect(contents.count == 1)
        #expect(contents[0]["role"]?.stringValue == "user")
    }

    @Test("Araç çağrısı functionCall parçasına dönüşür")
    func toolCallMapping() {
        let call = AIToolCall(id: "1", name: "create_task", arguments: .object(["title": "Spor"]))
        let contents = GeminiProvider.contents(from: [
            AIMessage(role: .assistant, text: "", toolCalls: [call])
        ])
        let part = contents[0]["parts"]?[0]
        #expect(part?["functionCall"]?["name"]?.stringValue == "create_task")
        #expect(part?["functionCall"]?["args"]?["title"]?.stringValue == "Spor")
    }

    @Test("Araç sonucu functionResponse parçasına dönüşür")
    func toolResultMapping() {
        let contents = GeminiProvider.contents(from: [
            .toolResult(id: "1", name: "create_task", content: "oluşturuldu")
        ])
        let response = contents[0]["parts"]?[0]?["functionResponse"]
        #expect(response?["name"]?.stringValue == "create_task")
        #expect(response?["response"]?["result"]?.stringValue == "oluşturuldu")
    }

    @Test("Boş asistan mesajı gönderilmez")
    func skipsEmptyAssistant() {
        // Metni de araç çağrısı da olmayan tur Gemini tarafından reddedilir.
        #expect(GeminiProvider.contents(from: [AIMessage(role: .assistant)]).isEmpty)
    }
}

// MARK: - Gemini boş yanıt teşhisi

@Suite("Gemini boş yanıt teşhisi")
struct GeminiOutcomeTests {

    @Test("Metin geldiyse teşhis üretilmez")
    func noDiagnosisWhenTextArrived() {
        var outcome = GeminiProvider.Outcome()
        outcome.sawText = true
        outcome.finishReason = "STOP"
        #expect(outcome.emptyResponseDiagnosis(maxTokens: 8192) == nil)
    }

    @Test("Araç çağrısı geldiyse teşhis üretilmez")
    func noDiagnosisWhenToolCalled() {
        var outcome = GeminiProvider.Outcome()
        outcome.sawToolCall = true
        #expect(outcome.emptyResponseDiagnosis(maxTokens: 8192) == nil)
    }

    @Test("Bütçe düşünmeye gittiyse sebebi ve token sayısı söylenir")
    func explainsThinkingExhaustedBudget() throws {
        // Asıl yaşanan hata: 64 token bütçe düşünmeye gitti, cevap kalmadı.
        var outcome = GeminiProvider.Outcome()
        outcome.finishReason = "MAX_TOKENS"
        outcome.sawThoughtPart = true
        outcome.usage.thinkingTokens = 64

        let diagnosis = try #require(outcome.emptyResponseDiagnosis(maxTokens: 64))
        #expect(diagnosis.contains("düşün"))
        #expect(diagnosis.contains("64"))
    }

    @Test("Güvenlik engeli ayrı raporlanır")
    func reportsSafetyBlock() throws {
        var outcome = GeminiProvider.Outcome()
        outcome.blockReason = "SAFETY"
        let diagnosis = try #require(outcome.emptyResponseDiagnosis(maxTokens: 8192))
        #expect(diagnosis.contains("SAFETY"))
    }

    @Test("Beklenmedik finishReason aynen aktarılır")
    func surfacesUnknownFinishReason() throws {
        var outcome = GeminiProvider.Outcome()
        outcome.finishReason = "RECITATION"
        let diagnosis = try #require(outcome.emptyResponseDiagnosis(maxTokens: 8192))
        #expect(diagnosis.contains("RECITATION"))
    }

    @Test("usageMetadata'dan düşünme token sayısı okunur")
    func absorbsThoughtTokens() throws {
        var outcome = GeminiProvider.Outcome()
        outcome.absorbUsage(try JSONValue.decode("""
        {"promptTokenCount":10,"thoughtsTokenCount":512,"totalTokenCount":530}
        """))
        #expect(outcome.thoughtsTokens == 512)
    }

    /// Kotaya takılmış bir anahtarla ikinci istek atmak kalan hakkı harcar.
    @Test("Ham teşhis yalnız ayrıştırma hatasında istenir")
    @MainActor
    func rawProbeOnlyForParseFailures() {
        #expect(AppEnvironment.deservesRawProbe(ATAKError.emptyResponse("boş")))
        #expect(!AppEnvironment.deservesRawProbe(ATAKError.provider("Gemini hatası (429) kota doldu")))
        #expect(!AppEnvironment.deservesRawProbe(ATAKError.provider("Gemini hatası (401)")))
        #expect(!AppEnvironment.deservesRawProbe(ATAKError.cancelled))
    }

    @Test("429 mesajı ücretsiz alternatifleri adıyla söyler")
    func quotaMessageNamesAlternatives() {
        let error = SSE.describeFailure(
            status: 429,
            body: Data(#"{"error":{"message":"Quota exceeded for metric"}}"#.utf8),
            provider: "Gemini"
        )
        let text = error.localizedDescription
        #expect(text.contains("Groq"))
        #expect(text.contains("Ollama"))
    }

    /// İki 429 türünün tavsiyesi zıt: birinde beklemek işe yarar, diğerinde yaramaz.
    @Test("Bakiye bitmesi hız sınırından ayrılır")
    func distinguishesBillingFromRateLimit() {
        let billing = SSE.describeFailure(
            status: 429,
            body: Data(#"{"error":{"message":"Your prepayment credits are depleted."}}"#.utf8),
            provider: "Gemini"
        ).localizedDescription

        #expect(billing.contains("DEĞİL"), "bakiye hatasında hız sınırı denmemeli")
        #expect(billing.contains("Beklemek çözmez"))

        let rateLimit = SSE.describeFailure(
            status: 429,
            body: Data(#"{"error":{"message":"Quota exceeded for metric: requests per minute"}}"#.utf8),
            provider: "Gemini"
        ).localizedDescription

        #expect(rateLimit.contains("dakikalık"))
        #expect(!rateLimit.contains("Beklemek çözmez"))
    }

    @Test(
        "Bakiye sinyalleri tanınır",
        arguments: [
            "Your prepayment credits are depleted.",
            "Billing account not configured",
            "insufficient funds",
        ]
    )
    func recognizesBillingSignals(message: String) {
        #expect(SSE.isBillingExhausted(message))
    }

    @Test("Hız sınırı mesajı bakiye sanılmaz")
    func rateLimitIsNotBilling() {
        #expect(!SSE.isBillingExhausted("Quota exceeded for metric: generativelanguage requests"))
        #expect(!SSE.isBillingExhausted("Rate limit exceeded, retry after 30s"))
    }

    @Test("Durma sebebi eşlemesi")
    func stopReasonMapping() {
        #expect(GeminiProvider.stopReason("STOP", sawToolCall: false) == .endTurn)
        #expect(GeminiProvider.stopReason("STOP", sawToolCall: true) == .toolUse)
        #expect(GeminiProvider.stopReason("MAX_TOKENS", sawToolCall: false) == .maxTokens)
        #expect(GeminiProvider.stopReason(nil, sawToolCall: false) == .endTurn)
    }
}

// MARK: - Araç kutusu

@Suite("Araç kutusu")
struct ToolboxTests {

    @Test("Tarih + saat ayrıştırılır")
    func parsesDateAndTime() throws {
        let date = try #require(ATAKToolbox.parseDate(date: "2026-08-14", time: "18:30"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 14)
        #expect(parts.hour == 18)
        #expect(parts.minute == 30)
    }

    @Test("Saat verilmezse gün sonuna ayarlanır")
    func defaultsToEvening() throws {
        let date = try #require(ATAKToolbox.parseDate(date: "2026-08-14", time: nil))
        #expect(Calendar.current.component(.hour, from: date) == 18)
    }

    @Test("Bozuk tarih nil döner", arguments: ["", "yarın", "14/08/2026", "2026-08"])
    func rejectsMalformedDates(input: String) {
        #expect(ATAKToolbox.parseDate(date: input, time: nil) == nil)
    }

    @Test("Öncelik adları eşlenir")
    func priorityNames() {
        #expect(TaskPriority.named("urgent") == .urgent)
        #expect(TaskPriority.named("HIGH") == .high)
        #expect(TaskPriority.named(nil) == .normal)
        #expect(TaskPriority.named("saçmalık") == .normal)
    }

    @Test("Her aracın adı ve şeması var")
    func specsAreWellFormed() async throws {
        let context = try await TestDatabase()
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database)
        )

        for spec in toolbox.specs {
            #expect(!spec.name.isEmpty)
            #expect(!spec.description.isEmpty)
            #expect(spec.parameters["type"]?.stringValue == "object")
        }
    }

    @Test("create_task gerçekten kaydeder ve doğrular")
    func createTaskPersists() async throws {
        let context = try await TestDatabase()
        let tasks = TaskService(database: context.database)
        let toolbox = ATAKToolbox(
            tasks: tasks,
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database)
        )

        let result = await toolbox.execute(AIToolCall(
            id: "1", name: "create_task",
            arguments: .object(["title": "Sunumu bitir", "priority": "high"])
        ))

        #expect(!result.isError)
        let saved = try await tasks.list(.open)
        #expect(saved.contains { $0.title == "Sunumu bitir" && $0.priority == .high })
    }

    @Test("Bilinmeyen araç hata döndürür, çökmez")
    func unknownToolIsHandled() async throws {
        let context = try await TestDatabase()
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database)
        )

        let result = await toolbox.execute(AIToolCall(id: "1", name: "roket_fırlat", arguments: .object([:])))
        #expect(result.isError)
    }

    @Test("Eksik zorunlu alan hata döndürür")
    func missingRequiredArgument() async throws {
        let context = try await TestDatabase()
        let toolbox = ATAKToolbox(
            tasks: TaskService(database: context.database),
            notes: NoteService(database: context.database),
            projects: ProjectService(database: context.database)
        )

        let result = await toolbox.execute(AIToolCall(id: "1", name: "create_task", arguments: .object([:])))
        #expect(result.isError)
    }
}

// MARK: - Token tasarrufu

@Suite("Geçmiş penceresi ve token")
struct HistoryTrimmingTests {

    private func message(_ role: AIRole, _ text: String) -> ChatMessage {
        ChatMessage(conversationID: UUID(), role: role, text: text)
    }

    @Test("Sınırın altındaki geçmiş olduğu gibi kalır")
    func shortHistoryUntouched() {
        let history = [message(.user, "a"), message(.assistant, "b")]
        #expect(ChatEngine.trimmed(history, limit: 20).count == 2)
    }

    @Test("Uzun geçmiş son mesajlara kırpılır")
    func trimsLongHistory() {
        let history = (0..<40).map { message($0.isMultiple(of: 2) ? .user : .assistant, "\($0)") }
        let trimmed = ChatEngine.trimmed(history, limit: 10)

        #expect(trimmed.count <= 10)
        #expect(trimmed.last?.text == "39")
    }

    /// Araç zincirinin ortasından başlayan pencere sağlayıcılarca reddediliyor.
    @Test("Pencere her zaman bir kullanıcı mesajıyla başlar")
    func windowStartsWithUserMessage() {
        var history: [ChatMessage] = []
        for index in 0..<10 {
            history.append(message(.user, "soru \(index)"))
            history.append(ChatMessage(
                conversationID: UUID(), role: .assistant, text: "",
                toolCalls: [AIToolCall(id: "\(index)", name: "create_task", arguments: .object([:]))]
            ))
            history.append(ChatMessage(
                conversationID: UUID(), role: .tool, text: "sonuç",
                toolCallID: "\(index)", toolName: "create_task"
            ))
        }

        for limit in [3, 5, 7, 11] {
            let trimmed = ChatEngine.trimmed(history, limit: limit)
            #expect(trimmed.first?.role == .user, "limit \(limit) için ilk mesaj kullanıcı olmalı")
        }
    }

    @Test("Kullanıcı mesajı içermeyen pencerede son kullanıcı turuna dönülür")
    func fallsBackToLastUserTurn() {
        let history = [
            message(.user, "soru"),
            message(.assistant, "a"), message(.assistant, "b"), message(.assistant, "c"),
        ]
        let trimmed = ChatEngine.trimmed(history, limit: 2)
        #expect(trimmed.first?.role == .user)
    }

    @Test("Token kullanımları toplanır")
    func usageAccumulates() {
        let first = AIUsage(inputTokens: 100, outputTokens: 20, thinkingTokens: 150)
        let second = AIUsage(inputTokens: 200, outputTokens: 30, thinkingTokens: 50)
        let total = first + second

        #expect(total.inputTokens == 300)
        #expect(total.outputTokens == 50)
        #expect(total.thinkingTokens == 200)
        #expect(total.total == 550)
    }

    @Test("Özet düşünme tokenini ayrı gösterir")
    func summaryShowsThinking() {
        let usage = AIUsage(inputTokens: 100, outputTokens: 20, thinkingTokens: 150)
        #expect(usage.shortSummary.contains("270"))
        #expect(usage.shortSummary.contains("150"))
    }

    @Test("thinkingConfig yalnız Gemini 3 ailesine gönderilir")
    func thinkingConfigGatedByModel() {
        #expect(GeminiProvider.supportsThinkingLevel("gemini-3.6-flash"))
        #expect(GeminiProvider.supportsThinkingLevel("gemini-3.5-flash-lite"))
        #expect(!GeminiProvider.supportsThinkingLevel("gemini-2.5-pro"))
    }

    /// Yerel modellerin çoğu araç çağrısı desteklemiyor; sohbet kırılmamalı.
    @Test("Araç reddi tanınır ve araçsız devam edilir")
    func detectsToolRejection() {
        #expect(OpenAICompatibleProvider.rejectedTools(
            ATAKError.provider("Ollama hatası (400)\nregistry.ollama.ai model does not support tools")
        ))
        #expect(OpenAICompatibleProvider.rejectedTools(
            ATAKError.provider("Groq hatası (400) function calling is not supported for this model")
        ))
    }

    @Test("Alakasız hatalar araç reddi sanılmaz")
    func unrelatedErrorsAreNotToolRejections() {
        #expect(!OpenAICompatibleProvider.rejectedTools(ATAKError.provider("Groq hatası (429) kota")))
        #expect(!OpenAICompatibleProvider.rejectedTools(ATAKError.provider("Ollama hatası (500) sunucu")))
        // 400 ama araçla ilgisiz
        #expect(!OpenAICompatibleProvider.rejectedTools(ATAKError.provider("Groq hatası (400) model not found")))
    }

    @Test("thinkingConfig reddedilirse tanınır ve geri çekilinir")
    func detectsThinkingRejection() {
        let rejected = ATAKError.provider("Gemini hatası (400)\nInvalid value at 'generation_config.thinking_config'")
        #expect(GeminiProvider.rejectedThinkingConfig(rejected))

        // Alakasız 400'ler geri çekilmeyi tetiklememeli.
        #expect(!GeminiProvider.rejectedThinkingConfig(ATAKError.provider("Gemini hatası (400) bad model")))
        #expect(!GeminiProvider.rejectedThinkingConfig(ATAKError.provider("Gemini hatası (429) kota")))
    }
}

// MARK: - Yapılandırma

@Suite("AI yapılandırması")
struct AIConfigurationTests {

    @Test("Sağlayıcı değişince model de o sağlayıcının varsayılanına döner")
    func switchingResetsModel() {
        // Aksi hâlde Gemini modeliyle Groq'a istek atılır ve 404 alınır.
        let gemini = AIConfiguration(providerID: .gemini, model: "gemini-2.5-flash")
        let groq = gemini.switching(to: .groq)

        #expect(groq.providerID == .groq)
        #expect(groq.model == AIProviderCatalog.info(for: .groq).defaultModel)
        #expect(groq.model != "gemini-2.5-flash")
    }

    /// Ayarlara alan eklemek kullanıcının kayıtlı tercihlerini silmemeli.
    @Test("Eski kayıtlı ayar yeni alanlar eklendikten sonra da okunur")
    func decodesConfigurationSavedBeforeNewFields() throws {
        // Diskteki gerçek biçim: thinkingLevel ve historyLimit henüz yokken.
        let legacy = """
        {"providerID":"gemini","model":"gemini-3.5-flash-lite","maxTokens":8192,
         "allowTools":true,"privateMode":false}
        """

        let decoded = try JSONDecoder().decode(AIConfiguration.self, from: Data(legacy.utf8))

        // Kullanıcının seçtiği model KORUNMALI.
        #expect(decoded.model == "gemini-3.5-flash-lite")
        #expect(decoded.providerID == .gemini)
        #expect(decoded.maxTokens == 8192)
        // Yeni alanlar varsayılana düşer.
        #expect(decoded.thinkingLevel == AIConfiguration.default.thinkingLevel)
        #expect(decoded.historyLimit == AIConfiguration.default.historyLimit)
    }

    @Test("Neredeyse boş ayar bile çökmez")
    func decodesMinimalConfiguration() throws {
        let decoded = try JSONDecoder().decode(
            AIConfiguration.self,
            from: Data(#"{"providerID":"groq"}"#.utf8)
        )
        #expect(decoded.providerID == .groq)
        // Model belirtilmemişse o sağlayıcının varsayılanı gelir.
        #expect(decoded.model == AIProviderCatalog.info(for: .groq).defaultModel)
    }

    @Test("Eski ses ayarı da korunur")
    func decodesLegacyVoiceSettings() throws {
        let decoded = try JSONDecoder().decode(
            VoiceSettings.self,
            from: Data(#"{"speakReplies":false}"#.utf8)
        )
        #expect(decoded.speakReplies == false)
        // Yeni kurulumlarda beklenmedik ses çıkışı olmaması için eksik alan
        // güvenli varsayılana düşer; açık tercih taşıyan eski kayıtlar korunur.
        #expect(decoded.greetOnLaunch == false)
    }

    @Test("Anahtar gerektirmeyen sağlayıcı her zaman hazır")
    func localProviderIsAlwaysReady() {
        #expect(AIConfiguration(providerID: .ollama).isReady)
    }

    @Test("Kapatılmış eski varsayılan model açılışta düzeltilir")
    @MainActor
    func repairsRetiredDefaultModel() {
        // gemini-2.5-flash yeni kullanıcılara kapatıldı; kayıtlı ayarda kalırsa
        // uygulama sebebi belirsiz bir 404 alır.
        let stale = AIConfiguration(providerID: .gemini, model: "gemini-2.5-flash")
        let repaired = AppEnvironment.repairingRetiredModel(stale)

        #expect(repaired.model == AIProviderCatalog.info(for: .gemini).defaultModel)
        #expect(repaired.model != "gemini-2.5-flash")
    }

    @Test("Kullanıcının kendi seçtiği model değiştirilmez")
    @MainActor
    func keepsUserChosenModel() {
        let custom = AIConfiguration(providerID: .gemini, model: "gemini-3.1-pro-preview")
        #expect(AppEnvironment.repairingRetiredModel(custom).model == "gemini-3.1-pro-preview")
    }

    @Test("Varsayılan modeller kapatılmışlar listesinde olamaz")
    @MainActor
    func defaultsAreNotRetired() {
        // Bu test, ileride yine bayat bir varsayılan göndermeyi engeller.
        for info in AIProviderCatalog.all {
            #expect(!AppEnvironment.retiredDefaultModels.contains(info.defaultModel))
        }
    }

    @Test("Her sağlayıcının kataloğu tutarlı")
    func catalogIsConsistent() {
        for info in AIProviderCatalog.all {
            #expect(!info.defaultModel.isEmpty)
            #expect(info.suggestedModels.contains(info.defaultModel))
            #expect(URL(string: info.baseURL) != nil)
            if info.requiresKey { #expect(info.keyPageURL != nil) }
        }
    }

    @Test("Anahtar gerektiren sağlayıcı anahtarsız kurulamaz")
    func refusesMissingKey() {
        #expect(throws: ATAKError.self) {
            _ = try AIProviderCatalog.makeProvider(for: .gemini, apiKey: nil)
        }
    }

    @Test("Bulut sağlayıcıları özel adrese API anahtarı göndermez")
    func cloudProvidersRejectEveryOverride() {
        let cloudProviders: [AIProviderID] = [.gemini, .groq, .openRouter, .anthropic]

        for provider in cloudProviders {
            #expect(throws: ATAKError.self) {
                _ = try AIProviderCatalog.makeProvider(
                    for: provider,
                    apiKey: "secret-test-key",
                    baseURLOverride: "https://attacker.example/v1"
                )
            }

            // Resmî adresin elle girilmiş kopyası da override sayılır. Güvenlik
            // sınırı yalnız kod içindeki denetlenmiş katalog adresini kullanır.
            #expect(throws: ATAKError.self) {
                _ = try AIProviderCatalog.validatedBaseURL(
                    for: provider,
                    override: AIProviderCatalog.info(for: provider).baseURL
                )
            }
        }
    }

    @Test("Katalogdaki bulut adresleri yalnız resmî HTTPS hostlarını kullanır")
    func cloudCatalogUsesTrustedHTTPSHosts() throws {
        for provider in [AIProviderID.gemini, .groq, .openRouter, .anthropic] {
            let info = AIProviderCatalog.info(for: provider)
            #expect(try AIProviderCatalog.validatedBaseURL(for: provider, override: nil) == info.baseURL)
        }
    }

    @Test("Ollama HTTP'de yalnız gerçek loopback adreslerini kabul eder")
    func ollamaAllowsOnlyLoopbackOverHTTP() throws {
        let accepted = [
            "http://localhost:11434/v1",
            "http://127.0.0.1:11434/v1",
            "http://[::1]:11434/v1",
        ]
        for address in accepted {
            #expect(try AIProviderCatalog.validatedBaseURL(for: .ollama, override: address) == address)
        }

        let rejected = [
            "http://ollama.internal:11434/v1",
            "http://0.0.0.0:11434/v1",
            "http://127.0.0.2:11434/v1",
            "http://localhost.evil.example:11434/v1",
        ]
        for address in rejected {
            #expect(throws: ATAKError.self) {
                _ = try AIProviderCatalog.validatedBaseURL(for: .ollama, override: address)
            }
        }
    }

    @Test("Uzak Ollama sunucusu şifreli HTTPS ile kullanılabilir")
    func ollamaAllowsRemoteHTTPS() throws {
        let address = "https://ollama.example.com/v1/"
        #expect(
            try AIProviderCatalog.validatedBaseURL(for: .ollama, override: address)
                == "https://ollama.example.com/v1"
        )
    }

    @Test("Kimlik bilgili, sorgulu, parçalı ve bozuk sunucu adresleri reddedilir")
    func rejectsAmbiguousOrCredentialedURLs() {
        let rejected = [
            "http://user:password@localhost:11434/v1",
            "http://localhost:11434/v1?redirect=https://attacker.example",
            "http://localhost:11434/v1#fragment",
            "ftp://localhost:11434/v1",
            "http://localhost:0/v1",
            "http://local host:11434/v1",
            "not-a-url",
        ]

        for address in rejected {
            #expect(throws: ATAKError.self) {
                _ = try AIProviderCatalog.validatedBaseURL(for: .ollama, override: address)
            }
        }
    }

    @Test("Sistem promptu bugünün tarihini ve güvenlik kuralını içerir")
    func systemPromptContent() {
        let prompt = ATAKPrompt.system(toolsEnabled: true)
        #expect(prompt.contains("ATAK"))
        #expect(prompt.contains(DateFormat.full(Date()).prefix(4)))
        #expect(prompt.lowercased().contains("uygulama"))

        // Araçlar kapalıyken araç yönergesi verilmemeli.
        #expect(!ATAKPrompt.system(toolsEnabled: false).contains("Araçların:"))
    }
}
