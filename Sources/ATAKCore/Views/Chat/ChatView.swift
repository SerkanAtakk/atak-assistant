import SwiftUI

public struct ChatView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var voice: VoiceService
    @Environment(\.atakTheme) private var theme
    @StateObject private var model = ChatViewModel()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            conversationList
                .frame(width: 210)
            Rectangle().fill(theme.hairline).frame(width: theme.hairlineWidth)
            conversationColumn
        }
        .atakBackground()
        .task {
            model.configure(environment)
            await model.load()
            model.greetIfNeeded()
        }
    }

    // MARK: - Sohbet listesi

    private var conversationList: some View {
        VStack(spacing: 0) {
            Button {
                model.startNewConversation()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Yeni sohbet")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.atakSecondary)
            .padding(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.conversations) { conversation in
                        conversationRow(conversation)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
        }
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        let isActive = model.activeConversation?.id == conversation.id

        return Button {
            Task { await model.select(conversation) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                if let date = conversation.lastMessageAt ?? Optional(conversation.startedAt) {
                    Text(DateFormat.relativeDay(date))
                        .font(theme.labelFont(size: 9.5))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
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

            Hairline()
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusIndicator(state: environment.agentState)
            Spacer()
            TechLabel(model.providerLabel)
            if model.isRunning {
                Button("Durdur") { model.stop() }
                    .buttonStyle(.atakSecondary)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
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
                        HStack(spacing: 6) {
                            ForEach(model.liveBadges) { badge in
                                ToolBadgeView(name: badge.name, detail: badge.summary, isError: badge.isError)
                            }
                            Spacer()
                        }
                        .id(Self.badgeAnchor)
                    }

                    if let error = model.errorMessage {
                        ErrorNotice(message: error)
                            .id(Self.errorAnchor)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: 780, alignment: .leading)
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
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme.accent)
                    .shadow(color: theme.glow > 0 ? theme.accent.opacity(0.5) : .clear, radius: theme.glow)

                Text(model.isConfigured ? environment.greeting : "ATAK hazır")
                    .font(theme.titleFont(size: 20))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(model.isConfigured
                     ? "Yazabilir ya da mikrofona basıp konuşabilirsin. Görev, not ve proje oluşturabilirim."
                     : "Başlamak için bir yapay zekâ sağlayıcısı bağlaman gerekiyor.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            if model.isConfigured {
                FlowRow(items: ChatViewModel.suggestions.map(Suggestion.init)) { suggestion in
                    Button {
                        model.input = suggestion.text
                    } label: {
                        Text(suggestion.text)
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textSecondary)
                    .background {
                        Capsule().fill(theme.surfaceRaised.opacity(theme.panelOpacity))
                    }
                    .overlay {
                        Capsule().strokeBorder(theme.hairline, lineWidth: theme.hairlineWidth)
                    }
                }
            } else {
                Button("Sağlayıcı bağla") { router.select(.settings) }
                    .buttonStyle(.atakPrimary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }

    private struct Suggestion: Identifiable {
        let text: String
        var id: String { text }
        init(_ text: String) { self.text = text }
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
                    model.send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.atakPrimary)
                .disabled(
                    model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isRunning
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
                    Text("Privacy Mode açık — bu sohbet diske kaydedilmiyor")
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

// MARK: - Mesaj satırı

struct MessageRow: View {
    @Environment(\.atakTheme) private var theme
    let message: ChatMessage
    var isStreaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                TechLabel(
                    message.role == .user ? "SEN" : "ATAK",
                    color: message.role == .user ? theme.textTertiary : theme.accent
                )
                if isStreaming {
                    TypingIndicator()
                }
                Spacer()
            }

            if !message.text.isEmpty {
                Text(Self.rendered(message.text))
                    .font(.system(size: 13.5))
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !message.toolCalls.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.toolCalls) { call in
                        ToolBadgeView(
                            name: ChatEngine.friendlyName(call.name),
                            detail: nil,
                            isError: false
                        )
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, message.role == .user ? 0 : 0)
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
