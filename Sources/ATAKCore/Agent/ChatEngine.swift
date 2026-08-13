import Foundation

/// Agent döngüsü bütçesi (MIMARI §2).
///
/// Sonsuz döngü ve maliyet patlaması koruması. Bütçe aşılırsa ATAK sessizce
/// durmaz; kullanıcıya nereye kadar geldiğini söyler.
public struct AgentBudget: Sendable {
    public var maxIterations: Int
    public var maxToolCalls: Int
    public var wallClock: TimeInterval

    public init(maxIterations: Int = 5, maxToolCalls: Int = 8, wallClock: TimeInterval = 120) {
        self.maxIterations = maxIterations
        self.maxToolCalls = maxToolCalls
        self.wallClock = wallClock
    }

    public static let `default` = AgentBudget()
}

public enum ChatEngineEvent: Sendable {
    case state(AgentState)
    case delta(String)
    /// Kalıcılaştırılması gereken tamamlanmış mesaj.
    case message(ChatMessage)
    case toolInvoked(name: String, summary: String, isError: Bool)
    case usage(AIUsage)
    case failed(String)
    case finished
}

/// Model ↔ araç döngüsünü yürüten çekirdek.
///
/// Kalıcılık yapmaz — ürettiği mesajları olay olarak yayınlar, kaydetme
/// kararını çağıran verir (Privacy Mode bu sayede tek yerde yönetilir).
public struct ChatEngine: Sendable {

    private let provider: any AIProvider
    private let configuration: AIConfiguration
    private let toolbox: ATAKToolbox?
    private let budget: AgentBudget
    /// Kullanıcı hakkında hatırlananların özeti; sistem promptuna eklenir.
    private let memoryDigest: String

    public init(
        provider: any AIProvider,
        configuration: AIConfiguration,
        toolbox: ATAKToolbox?,
        budget: AgentBudget = .default,
        memoryDigest: String = ""
    ) {
        self.provider = provider
        self.configuration = configuration
        self.toolbox = toolbox
        self.budget = budget
        self.memoryDigest = memoryDigest
    }

    public func run(
        conversationID: UUID,
        history: [ChatMessage]
    ) -> AsyncStream<ChatEngineEvent> {
        AsyncStream { continuation in
            let task = Task {
                await execute(
                    conversationID: conversationID,
                    history: history,
                    emit: { continuation.yield($0) }
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        conversationID: UUID,
        history: [ChatMessage],
        emit: @Sendable (ChatEngineEvent) -> Void
    ) async {
        let deadline = Date().addingTimeInterval(budget.wallClock)
        let useTools = configuration.allowTools && toolbox != nil && provider.capabilities.supportsTools
        let specs = useTools ? (toolbox?.specs ?? []) : []

        // Tüm geçmişi her turda göndermek girdi tokenlerini sürekli büyütür;
        // pencere sınırlanıyor (MIMARI §24: kısa vadeli bağlam).
        var conversation = Self.trimmed(history, limit: configuration.historyLimit)
            .map(\.asAIMessage)
        var toolCallsUsed = 0

        for iteration in 0..<budget.maxIterations {
            if Task.isCancelled { emit(.finished); return }

            guard Date() < deadline else {
                emit(.failed("İşlem \(Int(budget.wallClock)) saniyelik sınıra takıldı. Buraya kadar yapılanlar kaydedildi."))
                return
            }

            emit(.state(iteration == 0 ? .thinking : .working(tool: "yanıt")))

            let request = AIRequest(
                model: configuration.model,
                system: ATAKPrompt.system(toolsEnabled: useTools, memoryDigest: memoryDigest),
                messages: conversation,
                tools: specs,
                maxTokens: configuration.maxTokens,
                thinkingLevel: configuration.thinkingLevel
            )

            var text = ""
            var calls: [AIToolCall] = []

            do {
                for try await event in provider.stream(request) {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let chunk):
                        text += chunk
                        emit(.delta(chunk))
                    case .toolCall(let call):
                        calls.append(call)
                    case .usage(let used):
                        emit(.usage(used))
                    case .finished:
                        break
                    }
                }
            } catch {
                // Kısmi metin geldiyse kaybolmasın.
                if !text.isEmpty {
                    emit(.message(ChatMessage(
                        conversationID: conversationID, role: .assistant,
                        text: text, model: configuration.model
                    )))
                }
                emit(.failed(error.localizedDescription))
                return
            }

            if Task.isCancelled {
                if !text.isEmpty {
                    emit(.message(ChatMessage(
                        conversationID: conversationID, role: .assistant,
                        text: text, model: configuration.model
                    )))
                }
                emit(.finished)
                return
            }

            let assistantMessage = ChatMessage(
                conversationID: conversationID,
                role: .assistant,
                text: text,
                toolCalls: calls,
                model: configuration.model
            )
            conversation.append(assistantMessage.asAIMessage)
            emit(.message(assistantMessage))

            guard !calls.isEmpty, let toolbox else {
                emit(.state(.ready))
                emit(.finished)
                return
            }

            for call in calls {
                if Task.isCancelled { emit(.finished); return }

                guard toolCallsUsed < budget.maxToolCalls else {
                    emit(.failed("Araç çağrısı sınırına (\(budget.maxToolCalls)) ulaşıldı; ATAK burada durdu."))
                    return
                }
                toolCallsUsed += 1

                emit(.state(.working(tool: Self.friendlyName(call.name))))
                // Özel oturumda sohbet satırı veritabanına hiç yazılmaz; denetim
                // kaydını ona bağlamak yabancı anahtar ihlaline yol açar ve kayıt
                // sessizce düşerdi (geri alma da bu yüzden çalışmazdı). İş yine
                // deftere girer, yalnız bir sohbete bağlanmaz — araçların diske
                // yazdığı görev/not zaten kalıcı olduğu için bu ek bir ifşa değil.
                let result = await toolbox.execute(
                    call,
                    conversationID: configuration.privateMode ? nil : conversationID
                )

                emit(.toolInvoked(
                    name: Self.friendlyName(call.name),
                    summary: result.summary,
                    isError: result.isError
                ))

                let resultMessage = ChatMessage(
                    conversationID: conversationID,
                    role: .tool,
                    text: result.content,
                    toolCallID: call.id,
                    toolName: call.name,
                    isError: result.isError
                )
                conversation.append(resultMessage.asAIMessage)
                emit(.message(resultMessage))
            }
        }

        emit(.failed("ATAK \(budget.maxIterations) adımda sonuca ulaşamadı ve durdu."))
    }

    /// Modele gönderilecek geçmişi son `limit` mesajla sınırlar.
    ///
    /// Pencere bir araç zincirinin ortasından başlarsa (asistanın çağrısı
    /// dışarıda, sonucu içeride) sağlayıcılar isteği reddediyor; bu yüzden
    /// başlangıç her zaman bir kullanıcı mesajına çekilir.
    static func trimmed(_ history: [ChatMessage], limit: Int) -> [ChatMessage] {
        guard limit > 0, history.count > limit else { return history }

        let window = Array(history.suffix(limit))
        if let start = window.firstIndex(where: { $0.role == .user }) {
            return Array(window[start...])
        }
        // Pencerede hiç kullanıcı mesajı yoksa son kullanıcı turundan başla.
        if let lastUser = history.lastIndex(where: { $0.role == .user }) {
            return Array(history[lastUser...])
        }
        return window
    }

    /// Araç adının kullanıcıya gösterilen hâli.
    ///
    /// Ad ve risk künyesi aynı tabloda duruyor (`ATAKToolbox.safety`); ikisini
    /// ayrı listelerde tutmak, yeni araç eklendiğinde birinin unutulması
    /// demekti.
    static func friendlyName(_ toolName: String) -> String {
        ATAKToolbox.safety(for: toolName)?.friendlyName ?? toolName
    }
}
