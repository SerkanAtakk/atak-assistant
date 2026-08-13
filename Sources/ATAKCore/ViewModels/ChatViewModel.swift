import Foundation
import Combine

public struct ToolBadge: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let name: String
    public let summary: String
    public let isError: Bool
}

@MainActor
public final class ChatViewModel: ObservableObject {

    @Published public private(set) var conversations: [Conversation] = []
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var activeConversation: Conversation?

    /// Akış sırasında biriken metin — henüz kalıcılaşmamış asistan yanıtı.
    @Published public private(set) var streamingText = ""
    @Published public private(set) var liveBadges: [ToolBadge] = []
    @Published public private(set) var isRunning = false
    /// Son turun ve bu oturumun token tüketimi — nereye gittiği görünsün diye.
    @Published public private(set) var lastUsage: AIUsage?
    @Published public private(set) var sessionUsage = AIUsage()

    @Published public var input = ""
    @Published public var errorMessage: String?
    /// Bu turda geri alınabilecek son iş. Tur bitince doldurulur.
    @Published public private(set) var undoCandidate: AssistantAction?
    /// Kısa onay bildirimi ("Geri alındı: …").
    @Published public private(set) var notice: String?

    private weak var environment: AppEnvironment?
    private var runTask: Task<Void, Never>?
    private var hasGreeted = false

    public init() {}

    public func configure(_ environment: AppEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment

        // Konuşma bitince metin doğrudan gönderilir — kullanıcı ayrıca
        // Enter'a basmak zorunda kalmasın.
        environment.voice.onFinalTranscript = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.input = text
                self.send()
            }
        }
    }

    /// Uygulama açılınca ATAK'ın sesli karşılaması (spec §26).
    ///
    /// Yalnız boş bir sohbette ve oturumda bir kez çalışır; ekran değiştirip
    /// geri gelince tekrar konuşmaz.
    public func greetIfNeeded() {
        guard let environment, !hasGreeted else { return }
        guard environment.voiceSettings.greetOnLaunch else {
            Log.app.info("karşılama: ayardan kapalı")
            return
        }
        // Eski koşul sohbet geçmişi boş olmasını da şart koşuyordu; ilk
        // konuşmadan sonra uygulama bir daha hiç karşılamıyordu. Karşılama
        // oturum başına birdir — geçmişin dolu olması onu engellememeli.
        guard !isRunning else { return }

        hasGreeted = true
        environment.voice.speak(environment.greeting)
    }

    public func toggleListening() {
        guard let environment else { return }
        Task { await environment.voice.toggleListening() }
    }

    public var isConfigured: Bool {
        environment?.aiConfiguration.isReady ?? false
    }

    public var providerLabel: String {
        guard let configuration = environment?.aiConfiguration else { return "—" }
        return "\(configuration.info.displayName) · \(configuration.model)"
    }

    // MARK: - Yükleme

    public func load() async {
        guard let service = environment?.conversations else { return }
        do {
            conversations = try await service.recent()
            if activeConversation == nil, let first = conversations.first {
                await select(first)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func select(_ conversation: Conversation) async {
        guard let service = environment?.conversations else { return }
        stop()
        activeConversation = conversation
        streamingText = ""
        liveBadges = []
        do {
            messages = try await service.messages(in: conversation.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func startNewConversation() {
        stop()
        activeConversation = nil
        messages = []
        streamingText = ""
        liveBadges = []
    }

    public func delete(_ conversation: Conversation) async {
        guard let service = environment?.conversations else { return }

        // Özel sohbetin veritabanında karşılığı yoktur. Bellekteki oturumu
        // kapatmak yeterli; böylece Privacy Mode'da gereksiz bir yazma
        // ifadesi dahi çalıştırılmaz.
        guard !conversation.isPrivate else {
            if activeConversation?.id == conversation.id { startNewConversation() }
            return
        }

        do {
            try await service.delete(conversation.id)
            if activeConversation?.id == conversation.id { startNewConversation() }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Gönderme

    public func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, let environment else { return }

        input = ""
        runTask = Task { await performSend(text, environment: environment) }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        environment?.voice.stopSpeaking()
        // Ekranda bekleyen bir onay kartı varsa serbest bırakılmalı: aksi
        // hâlde araç sonsuza kadar cevap bekler ve kart ekranda asılı kalır.
        environment?.consentGate.cancelPending()
        environment?.agentState = .ready
    }

    private func performSend(_ text: String, environment: AppEnvironment) async {
        guard let service = environment.conversations else { return }
        let isPrivate = environment.aiConfiguration.privateMode

        isRunning = true
        errorMessage = nil
        notice = nil
        undoCandidate = nil
        streamingText = ""
        liveBadges = []
        defer {
            isRunning = false
            environment.agentState = .ready
        }

        // Motoru mesaj kaydetmeden önce kur; anahtar yoksa boş sohbet kalmasın.
        let engine: ChatEngine
        do {
            engine = try await environment.makeChatEngine()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // Sohbet yoksa oluştur, başlığı ilk mesajdan türet. Privacy Mode
        // normal bir sohbetin ortasında açılıp kapanmış olabilir; farklı
        // kalıcılık kipindeki sohbeti yeniden kullanmak özel mesajları açık
        // geçmişe karıştırır veya kaydedilmemiş bir kimliğe yazmaya çalışır.
        let conversation: Conversation
        if let active = activeConversation, active.isPrivate == isPrivate {
            conversation = active
        } else {
            do {
                // Kip değiştiyse önceki sohbetin mesajları yeni oturumun
                // model geçmişine taşınmamalı.
                messages = []
                let created = try await service.create(
                    title: String(text.prefix(60)),
                    isPrivate: isPrivate
                )
                conversation = created
                activeConversation = created
                // Özel sohbet listeye hiç girmez; başlığı ve kimliği yalnız
                // activeConversation içinde yaşar.
                if !isPrivate { await load() }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        let userMessage = ChatMessage(conversationID: conversation.id, role: .user, text: text)
        messages.append(userMessage)
        try? await service.append(userMessage, isPrivate: isPrivate)

        var turnUsage = AIUsage()

        for await event in engine.run(conversationID: conversation.id, history: messages) {
            switch event {
            case .state(let state):
                environment.agentState = state

            case .usage(let used):
                // Bir turda birden çok model çağrısı olabilir (araç döngüsü);
                // hepsi toplanır.
                turnUsage = turnUsage + used
                lastUsage = turnUsage
                sessionUsage = sessionUsage + used

            case .delta(let chunk):
                streamingText += chunk

            case .message(let message):
                // Asistan metni akışta zaten gösterildi; kalıcı hâli listeye girince
                // geçici metni temizle ki çift görünmesin.
                if message.role == .assistant {
                    streamingText = ""
                    // Sesli okuma akış bitince yapılır: parça parça okumak
                    // kelimeleri bölerdi.
                    if environment.voiceSettings.speakReplies, !message.text.isEmpty {
                        environment.voice.speak(message.text)
                    }
                }
                messages.append(message)
                try? await service.append(message, isPrivate: isPrivate)

            case .toolInvoked(let name, let summary, let isError):
                liveBadges.append(ToolBadge(name: name, summary: summary, isError: isError))

            case .failed(let message):
                errorMessage = message
                environment.agentState = .error(message)

            case .finished:
                break
            }
        }

        // Kalıcı sohbetin liste tarihi/başlığı yenilenir. Özel oturumda ise
        // mesajlar ve metadata bellekte bırakılır, veritabanına dokunulmaz.
        if !isPrivate { await load() }

        // Geri alma yalnız bu turda gerçekten bir iş yapıldıysa önerilir;
        // sohbet boyunca duran kalıcı bir düğme, kullanıcının ne geri
        // alacağını bilmeden basmasına yol açardı.
        undoCandidate = liveBadges.isEmpty
            ? nil
            : try? await environment.undo?.candidate()
    }

    /// Sohbetteki "Geri al" şeridi.
    public func undoLast() async {
        guard let environment, let candidate = undoCandidate else { return }
        do {
            guard let described = try await environment.undo?.undo(candidate) else { return }
            undoCandidate = nil
            notice = "Geri alındı: \(described)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func dismissUndo() {
        undoCandidate = nil
    }

    // MARK: - Görüntüleme

    public var visibleMessages: [ChatMessage] {
        messages.filter(\.isVisibleInTranscript)
    }

    public var isEmpty: Bool {
        visibleMessages.isEmpty && streamingText.isEmpty && !isRunning
    }

    /// Boş ekranda gösterilen örnek istekler.
    ///
    /// Yalnız süs değil: kullanıcının hangi yeteneklerin var olduğunu
    /// keşfetmesinin en kısa yolu. v0.3'ün yeni araçları burada temsil ediliyor.
    public static let suggestions = [
        "Bugün ne yapmalıyım?",
        "Yarın 18:00'e spor görevi ekle",
        "Bu hafta ne zaman boşum?",
        "25 dakika odaklanalım",
        "Salı ve perşembe spor yaptığımı hatırla",
        "Şunu not al: ",
    ]
}
