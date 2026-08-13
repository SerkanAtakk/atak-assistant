import SwiftUI
import AppKit

public struct ChatView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var voice: VoiceService
    @EnvironmentObject private var consentGate: ConsentGate
    @Environment(\.atakTheme) private var theme
    @StateObject private var model = ChatViewModel()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            conversationList
                .frame(width: 238)
            Rectangle().fill(theme.hairline).frame(width: theme.hairlineWidth)
            conversationColumn
        }
        .atakBackground()
        .task {
            model.configure(environment)
            await model.load()
            if let prompt = router.consumeChatPrompt() {
                model.input = prompt
            }
            model.greetIfNeeded()
        }
    }

    // MARK: - Sohbet listesi

    private var conversationList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TechLabel("Sohbet geçmişi")
                    Spacer()
                    Text("\(model.conversations.count)")
                        .font(theme.numericFont(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
                Button {
                    model.startNewConversation()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.and.pencil")
                        Text("Yeni sohbet")
                        Spacer()
                        Text("⌘N")
                            .font(theme.labelFont(size: 9))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.atakSecondary)
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(12)

            Hairline()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.conversations.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(theme.textTertiary)
                            Text("Sohbetlerin burada görünür")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                            Text("Özel moddaki konuşmalar kaydedilmez.")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                    }
                    ForEach(model.conversations) { conversation in
                        conversationRow(conversation)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
        }
        .background(theme.surface.opacity(theme.identifier == .hud ? 0.48 : 0.8))
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        let isActive = model.activeConversation?.id == conversation.id

        return Button {
            Task { await model.select(conversation) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isActive ? theme.accent : theme.textTertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.displayTitle)
                        .font(.system(size: 11.5, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                        .lineLimit(1)
                    if let date = conversation.lastMessageAt ?? Optional(conversation.startedAt) {
                        Text(DateFormat.relativeDay(date))
                            .font(theme.labelFont(size: 9))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                    .fill(isActive ? theme.accent.opacity(0.14) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Sil", role: .destructive) {
                Task { await model.delete(conversation) }
            }
        }
    }

    // MARK: - Konuşma sütunu

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            if model.isEmpty {
                welcome
            } else {
                transcript
            }

            // Onay kartı yazışmanın *içine* değil, altına konuyor: kaydırma
            // konumundan bağımsız olarak her zaman görünmeli — kullanıcının
            // fark etmediği bir onay isteği, olmayan onaydır.
            if let candidate = model.undoCandidate, let token = candidate.undo {
                Hairline()
                undoStrip(token)
            } else if let notice = model.notice {
                Hairline()
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.success)
                    Text(notice)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 9)
            }

            if let request = consentGate.pending {
                Hairline()
                ConsentCard(
                    request: request,
                    onApprove: { consentGate.approve() },
                    onDeny: { consentGate.deny() }
                )
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Hairline()
            composer
        }
    }

    /// ATAK bir kayıt oluşturduktan sonra çıkan tek satırlık geri alma şeridi.
    ///
    /// Onay sormadan çalışan orta riskli araçların karşılığı budur: kullanıcı
    /// durdurulmaz, ama yanlış olan tek tıkla geri alınır (MIMARI §5).
    private func undoStrip(_ token: UndoToken) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
            Text(token.undoDescription)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            Spacer()
            Button("Geri al") {
                Task { await model.undoLast() }
            }
            .buttonStyle(.atakSecondary)
            .controlSize(.small)
            Button {
                model.dismissUndo()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 9)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ATAKLogoMark(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeConversation?.displayTitle ?? "Yeni sohbet")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                StatusIndicator(state: environment.isAIReady ? environment.agentState : .offline)
            }
            Spacer()
            if environment.aiConfiguration.privateMode {
                Label("Diske kaydetme kapalı", systemImage: "eye.slash.fill")
                    .font(theme.labelFont(size: 9.5))
                    .foregroundStyle(theme.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.warning.opacity(0.1), in: Capsule())
            }
            Text(model.providerLabel)
                .font(theme.labelFont(size: 9.5))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.surface.opacity(0.5))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.visibleMessages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }

                    if !model.streamingText.isEmpty {
                        MessageRow(
                            message: ChatMessage(
                                conversationID: UUID(),
                                role: .assistant,
                                text: model.streamingText
                            ),
                            isStreaming: true
                        )
                        .id(Self.streamingAnchor)
                    }

                    if !model.liveBadges.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            TechLabel("Yapılan işlemler")
                            FlowRow(items: model.liveBadges) { badge in
                                ToolBadgeView(name: badge.name, detail: badge.summary, isError: badge.isError)
                            }
                        }
                        .id(Self.badgeAnchor)
                    }

                    if let error = model.errorMessage {
                        ErrorNotice(message: error)
                            .id(Self.errorAnchor)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.streamingText) { _, _ in
                proxy.scrollTo(Self.streamingAnchor, anchor: .bottom)
            }
            .onChange(of: model.visibleMessages.count) { _, _ in
                if let last = model.visibleMessages.last {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let streamingAnchor = "atak.streaming"
    private static let badgeAnchor = "atak.badges"
    private static let errorAnchor = "atak.error"

    // MARK: - Karşılama

    private var welcome: some View {
        ScrollView {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 10) {
                ATAKLogoMark(size: 52)

                Text(model.isConfigured ? environment.greeting : "ATAK hazır")
                    .font(theme.titleFont(size: 22))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(model.isConfigured
                     ? "Düşüncelerini netleştirebilir, görevlerini ve notlarını doğrudan düzenleyebilirim."
                     : "İki dakikalık bağlantı adımından sonra kişisel çalışma alanın hazır olacak.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            if model.isConfigured {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 9)], spacing: 9) {
                    ForEach(ChatViewModel.suggestions.map(Suggestion.init)) { suggestion in
                    Button {
                        model.input = suggestion.text
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: suggestion.icon)
                                .foregroundStyle(theme.accent)
                            Text(suggestion.text)
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.textSecondary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .panel(raised: true)
                    }
                }
                .frame(maxWidth: 540)
            } else {
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        SetupStep(number: "1", title: "Sağlayıcı seç", detail: "Gemini, Groq, Claude veya yerel Ollama")
                        SetupStep(number: "2", title: "Güvenle bağla", detail: "Anahtar yalnız Keychain'de saklanır")
                        SetupStep(number: "3", title: "İlk işi ver", detail: "ATAK sonucu doğrulayarak kaydeder")
                    }
                    Button("Kurulumu tamamla") { router.select(.settings) }
                        .buttonStyle(.atakPrimary)
                }
                .frame(maxWidth: 650)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(34)
        }
    }

    private struct Suggestion: Identifiable {
        let text: String
        var id: String { text }
        init(_ text: String) { self.text = text }

        /// Sırası önemli: daha özel eşleşme önce gelmeli, yoksa "spor"
        /// geçen bir hatırlama önerisi koşu ikonu alır.
        var icon: String {
            if text.contains("hatırla") { return "brain" }
            if text.contains("odak") { return "timer" }
            if text.contains("boş") || text.contains("hafta") { return "calendar" }
            if text.contains("spor") { return "figure.run" }
            if text.contains("not") { return "note.text" }
            return "sparkles"
        }
    }

    // MARK: - Yazma alanı

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                micButton

                if voice.isListening {
                    // Dinlerken canlı transkript gösterilir; kullanıcı ne
                    // anlaşıldığını anında görür.
                    Text(voice.transcript.isEmpty ? "Dinliyorum…" : voice.transcript)
                        .font(.system(size: 13))
                        .foregroundStyle(voice.transcript.isEmpty ? theme.textTertiary : theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(3)
                } else {
                    TextField(
                        model.isConfigured ? "ATAK'a yaz…" : "Önce Ayarlar'dan sağlayıcı bağla",
                        text: $model.input,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1...6)
                    .disabled(!model.isConfigured || model.isRunning)
                    .onSubmit { model.send() }
                }

                Button {
                    model.isRunning ? model.stop() : model.send()
                } label: {
                    Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.atakPrimary)
                .disabled(
                    (!model.isRunning && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    || !model.isConfigured
                )
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .panel(raised: true, accented: model.isRunning)

            if let usage = model.lastUsage {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                    Text("son yanıt: \(usage.shortSummary)")
                    if model.sessionUsage.total != usage.total {
                        Text("· oturum: \(model.sessionUsage.total)")
                    }
                    Spacer()
                }
                .font(theme.labelFont(size: 10))
                .foregroundStyle(theme.textTertiary)
                .help("Ücretsiz katman kotanın nereye gittiğini görmek için")
            }

            if let voiceError = voice.errorMessage {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "mic.slash")
                    Text(voiceError)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .font(theme.labelFont(size: 10))
                .foregroundStyle(theme.warning)
            }

            if voice.isSpeaking {
                HStack(spacing: 5) {
                    Image(systemName: "speaker.wave.2.fill")
                    Text("ATAK konuşuyor")
                    Button("Sustur") { voice.stopSpeaking() }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent)
                    Spacer()
                }
                .font(theme.labelFont(size: 10))
                .foregroundStyle(theme.textTertiary)
            }

            if environment.aiConfiguration.privateMode {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash")
                    Text("Özel mod: bu sohbet diske yazılmaz. Bulut sağlayıcısı seçiliyse mesaj yine sağlayıcıya gönderilir.")
                    Spacer()
                }
                .font(theme.labelFont(size: 10))
                .foregroundStyle(theme.warning)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 812)
        .frame(maxWidth: .infinity)
    }

    /// Bas-konuş düğmesi (spec §26: sürekli dinleme varsayılan olarak kapalı).
    private var micButton: some View {
        Button {
            model.toggleListening()
        } label: {
            Image(systemName: voice.isListening ? "waveform" : "mic")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 17, height: 17)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(voice.isListening ? theme.accent : theme.textSecondary)
        .padding(5)
        .background {
            Circle().fill(voice.isListening ? theme.accent.opacity(0.16) : Color.clear)
        }
        .overlay {
            if voice.isListening, theme.glow > 0 {
                Circle()
                    .strokeBorder(theme.accent.opacity(0.5), lineWidth: 1)
                    .phaseAnimator([0.6, 1.25]) { view, phase in
                        view.scaleEffect(phase).opacity(2 - phase)
                    } animation: { _ in
                        .easeOut(duration: 1.0)
                    }
            }
        }
        .keyboardShortcut("m", modifiers: .command)
        .disabled(!model.isConfigured || model.isRunning)
        .help(voice.isListening ? "Dinlemeyi bitir ve gönder (⌘M)" : "Konuşarak anlat (⌘M)")
    }
}

private struct SetupStep: View {
    @Environment(\.atakTheme) private var theme
    let number: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(number)
                .font(theme.numericFont(size: 10, weight: .bold))
                .foregroundStyle(theme.background)
                .frame(width: 22, height: 22)
                .background(theme.accent, in: Circle())
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .topLeading)
        .panel(raised: true)
    }
}

// MARK: - Mesaj satırı

struct MessageRow: View {
    @Environment(\.atakTheme) private var theme
    let message: ChatMessage
    var isStreaming: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user { Spacer(minLength: 72) }

            if message.role != .user {
                ATAKLogoMark(size: 27)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 7) {
                HStack(spacing: 7) {
                    if message.role == .user { Spacer() }
                    TechLabel(
                        message.role == .user ? "Sen" : "ATAK",
                        color: message.role == .user ? theme.textTertiary : theme.accent
                    )
                    if isStreaming { TypingIndicator() }
                    Text(DateFormat.relativeDay(message.createdAt))
                        .font(theme.labelFont(size: 8.5))
                        .foregroundStyle(theme.textTertiary)
                    if message.role != .user { Spacer() }
                }

                if !message.text.isEmpty {
                    Text(Self.rendered(message.text))
                        .font(.system(size: 13.5))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, message.role == .user ? 13 : 15)
                        .padding(.vertical, message.role == .user ? 10 : 13)
                        .background {
                            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                                .fill(message.role == .user ? theme.accent.opacity(0.13) : theme.surface.opacity(0.88))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                                .strokeBorder(message.role == .user ? theme.accent.opacity(0.22) : theme.hairline,
                                              lineWidth: theme.hairlineWidth)
                        }
                        .contextMenu {
                            Button("Metni kopyala") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.text, forType: .string)
                            }
                        }
                }

                if !message.toolCalls.isEmpty {
                    FlowRow(items: message.toolCalls) { call in
                        ToolBadgeView(name: ChatEngine.friendlyName(call.name), detail: nil, isError: false)
                    }
                }
            }
            .frame(maxWidth: message.role == .user ? 560 : .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user { Spacer(minLength: 24) }
        }
        .frame(maxWidth: .infinity)
    }

    /// Basit markdown (kalın, italik, kod) desteklenir; satır düzeni korunur.
    private static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - Araç rozeti

struct ToolBadgeView: View {
    @Environment(\.atakTheme) private var theme
    let name: String
    let detail: String?
    let isError: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 9))
            Text(detail.map { "\(name) · \($0)" } ?? name)
                .font(theme.labelFont(size: 10))
        }
        .foregroundStyle(isError ? theme.danger : theme.success)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill((isError ? theme.danger : theme.success).opacity(0.12))
        }
    }
}

// MARK: - Yazıyor göstergesi

struct TypingIndicator: View {
    @Environment(\.atakTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(theme.accent)
                    .frame(width: 3.5, height: 3.5)
                    .phaseAnimator([0.25, 1.0]) { view, phase in
                        view.opacity(phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.45).delay(Double(index) * 0.15)
                    }
            }
        }
    }
}

// MARK: - Hata bildirimi

struct ErrorNotice: View {
    @Environment(\.atakTheme) private var theme
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.danger)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                .fill(theme.danger.opacity(0.09))
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                .strokeBorder(theme.danger.opacity(0.3), lineWidth: theme.hairlineWidth)
        }
    }
}
