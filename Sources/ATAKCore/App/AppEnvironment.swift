import Foundation
import Combine

/// Uygulama genelinde paylaşılan bağımlılıklar.
@MainActor
public final class AppEnvironment: ObservableObject {

    public enum Status: Equatable {
        case starting
        case ready
        case failed(String)
    }

    @Published public private(set) var status: Status = .starting
    @Published public private(set) var aiConfiguration: AIConfiguration = .default
    @Published public private(set) var themeIdentifier: ATAKTheme.Identifier = .minimal
    @Published public private(set) var voiceSettings: VoiceSettings = .default
    @Published public private(set) var userName: String = UserIdentity.defaultFirstName()
    @Published public var agentState: AgentState = .ready

    public let router = AppRouter()
    public let voice = VoiceService()
    /// Riskli araçların beklediği onay kapısı (MIMARI §8).
    public let consentGate = ConsentGate()
    public let focusTimer = FocusTimer()

    /// "Günaydın Serkan, ne yapıyoruz?"
    public var greeting: String {
        let address = userName.isEmpty ? "" : " \(userName)"
        return "\(DateFormat.greeting())\(address), ne yapıyoruz?"
    }

    public var theme: ATAKTheme { .theme(for: themeIdentifier) }

    public var isAIReady: Bool { aiConfiguration.isReady }

    public private(set) var database: Database?
    public private(set) var tasks: TaskService?
    public private(set) var projects: ProjectService?
    public private(set) var notes: NoteService?
    public private(set) var conversations: ConversationService?
    public private(set) var preferences: PreferencesService?
    public private(set) var memory: MemoryService?
    public private(set) var actionLog: ActionLogService?
    public private(set) var timerSessions: TimerSessionService?
    public private(set) var undo: UndoService?
    public private(set) var toolbox: ATAKToolbox?

    /// Takvim erişimi. İzin istenene kadar hiçbir şey yapmaz — nesnenin
    /// varlığı TCC'yi tetiklemez.
    public let calendar = CalendarService()

    /// Devam eden başlatma işi. Birden fazla çağıran aynı işi bekler.
    private var bootstrapTask: Task<Void, Never>?

    public init() {}

    /// Veritabanını açar, şemayı taşır, servisleri ve ayarları kurar.
    ///
    /// Birden çok yerden çağrılabilir (pencerenin `.task`'ı, menü, smoke
    /// kontrolü) ve iş yalnızca bir kez yapılır. Basit bir `guard status`
    /// yetmezdi: fonksiyon ilk `await`'te askıya alındığında durum hâlâ
    /// `.starting` olduğu için ikinci çağıran da içeri girer ve migrasyon
    /// iki kez çalışırdı ("table user_profile already exists").
    /// `@MainActor` üzerinde olduğumuz için aşağıdaki kontrol-ve-atama
    /// arasında askıya alma noktası yok, dolayısıyla atomiktir.
    public func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        guard case .starting = status else { return }

        do {
            let url = Database.defaultURL()
            let database = try Database(path: url)
            try await database.migrate()

            let tasks = TaskService(database: database)
            let projects = ProjectService(database: database)
            let notes = NoteService(database: database)
            let preferences = PreferencesService(database: database)
            let memory = MemoryService(database: database)
            let actionLog = ActionLogService(database: database)
            let timerSessions = TimerSessionService(database: database)

            self.database = database
            self.tasks = tasks
            self.projects = projects
            self.notes = notes
            self.conversations = ConversationService(database: database)
            self.preferences = preferences
            self.memory = memory
            self.actionLog = actionLog
            self.timerSessions = timerSessions
            self.undo = UndoService(
                log: actionLog, tasks: tasks, notes: notes, projects: projects,
                memory: memory, calendar: calendar
            )
            focusTimer.configure(timerSessions)

            self.toolbox = ATAKToolbox(
                tasks: tasks,
                notes: notes,
                projects: projects,
                memory: memory,
                calendar: calendar,
                timer: FocusTimerProxy(focusTimer),
                actionLog: actionLog,
                consent: ConsentGateBridge(consentGate)
            )

            if let stored = try await preferences.decode(AIConfiguration.self, for: PreferenceKey.aiConfiguration) {
                let repaired = Self.repairingRetiredModel(stored)
                aiConfiguration = repaired
                if repaired != stored {
                    try? await preferences.encode(repaired, for: PreferenceKey.aiConfiguration)
                    Log.app.info("Kapatılmış model düzeltildi: \(stored.model, privacy: .public) → \(repaired.model, privacy: .public)")
                }
            }
            if let raw = try await preferences.string(PreferenceKey.theme),
               let identifier = ATAKTheme.Identifier(rawValue: raw) {
                themeIdentifier = identifier
            }
            if let stored = try await preferences.decode(VoiceSettings.self, for: PreferenceKey.voice) {
                voiceSettings = stored
            }
            if let stored = try await preferences.string(PreferenceKey.userName) {
                userName = stored
            }

            let version = try await database.currentSchemaVersion()
            Log.app.info("Veritabanı hazır — şema v\(version) — \(url.path)")
            status = .ready
        } catch {
            let message = error.localizedDescription
            Log.app.error("Başlatma başarısız: \(message)")
            status = .failed(message)
        }
    }

    // MARK: - Ayarlar

    /// ATAK'ın daha önce varsayılan olarak gönderdiği, sonradan sağlayıcı
    /// tarafından kapatılan model adları.
    ///
    /// Kullanıcının kayıtlı ayarı eski varsayılanda kalırsa uygulama 404 alır
    /// ve kullanıcı sebebini bilemez; açılışta sessizce güncel varsayılana
    /// çekiliyor. Kullanıcının kendi seçtiği bir model buraya girmez.
    static let retiredDefaultModels: Set<String> = ["gemini-2.5-flash"]

    /// ATAK'ın eskiden gönderdiği, düşünen modeller için fazla dar kalan bütçe.
    static let staleDefaultMaxTokens = 4096

    static func repairingRetiredModel(_ configuration: AIConfiguration) -> AIConfiguration {
        var fixed = configuration

        if retiredDefaultModels.contains(configuration.model) {
            fixed.model = AIProviderCatalog.info(for: configuration.providerID).defaultModel
        }
        if configuration.maxTokens == staleDefaultMaxTokens {
            fixed.maxTokens = AIConfiguration.default.maxTokens
        }

        return fixed
    }

    /// Sağlayıcıdan, bu anahtara gerçekten açık model listesini alır.
    public func fetchAvailableModels() async -> Result<[String], Error> {
        do {
            let key = Keychain.get(Keychain.account(for: aiConfiguration.providerID))
            let provider = try AIProviderCatalog.makeProvider(
                for: aiConfiguration.providerID,
                apiKey: key,
                baseURLOverride: aiConfiguration.baseURLOverride
            )
            let models = try await provider.availableModels()
            guard !models.isEmpty else {
                // Yerel sağlayıcıda boş liste "hata" değil, "henüz model
                // indirilmemiş" demek; kullanıcıya ne yapacağını söyle.
                let message = aiConfiguration.providerID == .ollama
                    ? "Ollama çalışıyor ama henüz hiç model indirilmemiş.\n"
                        + "Terminal'de bir model indir, sonra bu düğmeye tekrar bas:\n"
                        + "    ollama pull qwen3"
                    : "Sağlayıcı model listesi döndürmedi. Model adını elle girmen gerekebilir."
                return .failure(ATAKError.provider(message))
            }
            return .success(models)
        } catch {
            return .failure(error)
        }
    }

    public func updateConfiguration(_ configuration: AIConfiguration) {
        aiConfiguration = configuration
        Task { [preferences] in
            try? await preferences?.encode(configuration, for: PreferenceKey.aiConfiguration)
        }
    }

    public func updateVoiceSettings(_ settings: VoiceSettings) {
        voiceSettings = settings
        if !settings.speakReplies { voice.stopSpeaking() }
        Task { [preferences] in
            try? await preferences?.encode(settings, for: PreferenceKey.voice)
        }
    }

    public func updateUserName(_ name: String) {
        userName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [preferences, userName] in
            try? await preferences?.setString(userName, for: PreferenceKey.userName)
        }
    }

    public func updateTheme(_ identifier: ATAKTheme.Identifier) {
        themeIdentifier = identifier
        Task { [preferences] in
            try? await preferences?.setString(identifier.rawValue, for: PreferenceKey.theme)
        }
    }

    // MARK: - AI

    /// Mevcut ayarlarla çalışır bir sohbet motoru üretir.
    ///
    /// Hafıza özeti burada okunuyor: her turda güncel olmalı, çünkü kullanıcı
    /// sohbetin ortasında bir şey hatırlatmış olabilir. Özel oturumda hafıza
    /// hiç gönderilmez (MIMARI §8).
    public func makeChatEngine() async throws -> ChatEngine {
        let key = Keychain.get(Keychain.account(for: aiConfiguration.providerID))
        let provider = try AIProviderCatalog.makeProvider(
            for: aiConfiguration.providerID,
            apiKey: key,
            baseURLOverride: aiConfiguration.baseURLOverride
        )

        let digest = aiConfiguration.privateMode
            ? ""
            : ((try? await memory?.promptDigest()) ?? "")

        return ChatEngine(
            provider: provider,
            configuration: aiConfiguration,
            toolbox: aiConfiguration.allowTools ? toolbox : nil,
            memoryDigest: digest
        )
    }

    public struct ConnectionTest: Sendable {
        public var succeeded: Bool
        public var message: String
        /// Ayrıştırma başarısızsa sunucudan gelen ham satırlar.
        public var rawResponse: String?
    }

    /// Ayarlar ekranındaki "Bağlantıyı test et".
    ///
    /// Başarısız olursa ayrıca ham yanıtı çeker: "boş yanıt" deyip susmak
    /// yerine tel üzerinde ne geldiğini göstermek, sorunu tahmine bırakmıyor.
    public func testConnection() async -> ConnectionTest {
        let key = Keychain.get(Keychain.account(for: aiConfiguration.providerID))
        let provider: any AIProvider

        do {
            provider = try AIProviderCatalog.makeProvider(
                for: aiConfiguration.providerID,
                apiKey: key,
                baseURLOverride: aiConfiguration.baseURLOverride
            )
        } catch {
            return ConnectionTest(succeeded: false, message: error.localizedDescription)
        }

        // Bütçe cömert olmalı: düşünen modellerde (Gemini 3) düşünme de
        // çıktı bütçesinden yiyor, küçük sınırda cevaba yer kalmıyor.
        let request = AIRequest(
            model: aiConfiguration.model,
            system: "Kısa cevap ver.",
            messages: [.user("Tek kelimeyle cevap ver: bağlantı çalışıyor mu?")],
            maxTokens: max(aiConfiguration.maxTokens, 2048)
        )

        do {
            var reply = ""
            for try await event in provider.stream(request) {
                if case .textDelta(let chunk) = event { reply += chunk }
            }

            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ConnectionTest(succeeded: true, message: trimmed)
            }

            return ConnectionTest(
                succeeded: false,
                message: "Sağlayıcı bağlandı ama yanıttan metin çıkarılamadı.",
                rawResponse: await rawProbe(provider)
            )
        } catch {
            return ConnectionTest(
                succeeded: false,
                message: error.localizedDescription,
                // Ham teşhis YALNIZ ayrıştırma sorunlarında istenir. HTTP
                // hatalarında (401/404/429) ikinci bir istek bilgi katmaz;
                // kota hatasında ise kalan hakkı boşa harcar.
                rawResponse: Self.deservesRawProbe(error) ? await rawProbe(provider) : nil
            )
        }
    }

    static func deservesRawProbe(_ error: Error) -> Bool {
        if case ATAKError.emptyResponse = error { return true }
        return false
    }

    private func rawProbe(_ provider: any AIProvider) async -> String? {
        do {
            return try await provider.rawProbe(model: aiConfiguration.model)
        } catch {
            return "(ham teşhis alınamadı: \(error.localizedDescription))"
        }
    }

    // MARK: - Kendi kendini sınama (`make smoke`)

    public struct SelfCheckReport: Sendable {
        public var lines: [String] = []
        public var passed: Bool = true

        mutating func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { passed = false }
        }
    }

    public func selfCheck() async -> SelfCheckReport {
        var report = SelfCheckReport()

        await bootstrap()

        switch status {
        case .ready:
            report.check("Başlatma", true)
        case .failed(let message):
            report.check("Başlatma", false, message)
            return report
        case .starting:
            report.check("Başlatma", false, "tamamlanmadı")
            return report
        }

        guard let database else {
            report.check("Veritabanı", false, "yok")
            return report
        }

        do {
            let integrity = try await database.healthCheck()
            report.check("Bütünlük", integrity == "ok", integrity)

            let version = try await database.currentSchemaVersion()
            report.check("Şema sürümü", version == Migrator.all.count, "v\(version)")

            if let notes {
                let note = try await notes.create(title: "ATAK sağlık kontrolü", body: "geçici kayıt")
                let found = try await notes.search("sağlık")
                report.check("Not yazma + FTS5 arama", found.contains { $0.id == note.id })
                try await notes.delete(note.id)
                let afterDelete = try await notes.search("sağlık")
                report.check("Silme + FTS temizliği", !afterDelete.contains { $0.id == note.id })
            } else {
                report.check("Not servisi", false, "kurulmadı")
            }

            if let conversations {
                let conversation = try await conversations.create(title: "Sağlık kontrolü")
                try await conversations.append(
                    ChatMessage(conversationID: conversation.id, role: .user, text: "test"),
                    isPrivate: false
                )
                let messages = try await conversations.messages(in: conversation.id)
                report.check("Sohbet kalıcılığı", messages.count == 1)
                try await conversations.delete(conversation.id)
            } else {
                report.check("Sohbet servisi", false, "kurulmadı")
            }

            report.check(
                "AI yapılandırması",
                true,
                "\(aiConfiguration.info.displayName) · \(aiConfiguration.model)\(aiConfiguration.isReady ? "" : " (anahtar yok)")"
            )
            report.check("Tema", true, themeIdentifier.displayName)
        } catch {
            report.check("Veritabanı turu", false, error.localizedDescription)
        }

        return report
    }
}
