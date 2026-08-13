import SwiftUI
import AppKit

public struct SettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.atakTheme) private var theme
    @StateObject private var model = SettingsViewModel()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsHeader

                if !environment.isAIReady {
                    InlineNotice(
                        "Kurulumu tamamla",
                        message: "Bir sağlayıcı seçip anahtarını Keychain'e kaydet; ardından bağlantıyı test et.",
                        kind: .warning
                    )
                }

                providerSection
                personalSection
                appearanceSection
                behaviourSection
                voiceSection
                dataSection
                aboutSection
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Ayarlar")
        .task { model.configure(environment) }
    }

    private var settingsHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            ScreenHeader(
                "Ayarlar",
                subtitle: "Asistanın davranışını, bağlantısını ve yerel verilerini yönet.",
                eyebrow: "ATAK kontrol merkezi",
                systemImage: "gearshape.fill"
            )
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Circle()
                    .fill(environment.isAIReady ? theme.success : theme.warning)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(environment.isAIReady ? "Bağlı" : "Bağlantı bekliyor")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text(model.configuration.info.displayName)
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .panel(raised: true)
        }
    }

    // MARK: - Kişisel

    private var personalSection: some View {
        section("Kişisel") {
            VStack(alignment: .leading, spacing: 6) {
                TechLabel("ATAK sana nasıl hitap etsin")
                HStack(spacing: 8) {
                    TextField("adın", text: $model.nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { model.commitName() }
                    Button("Kaydet") { model.commitName() }
                        .buttonStyle(.atakSecondary)
                        .controlSize(.small)
                }
                Text("Karşılama: \"\(environment.greeting)\"")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    // MARK: - Ses

    private var voiceSection: some View {
        section("Ses") {
            Toggle(isOn: Binding(
                get: { model.voiceSettings.greetOnLaunch },
                set: { model.setGreetOnLaunch($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Açılışta sesli karşılasın")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textPrimary)
                    Text("Uygulamayı açtığında ATAK seni adınla selamlar.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Toggle(isOn: Binding(
                get: { model.voiceSettings.speakReplies },
                set: { model.setSpeakReplies($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yanıtları sesli okusun")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textPrimary)
                    Text("ATAK'ın cevaplarını yüksek sesle okur.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.textTertiary)
                }
            }

            HStack(spacing: 10) {
                Button("Sesi ve mikrofonu dene") {
                    Task { await model.testVoice() }
                }
                .buttonStyle(.atakPrimary)
                Spacer()
            }

            Text("Konuşmak için sohbetteki mikrofon düğmesine bas ya da ⌘M. Tekrar basınca ATAK duyduğunu gönderir. Sürekli dinleme kapalıdır — mikrofon yalnız sen başlattığında açılır.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Yapay zekâ

    private var providerSection: some View {
        section("Yapay Zekâ") {
            VStack(alignment: .leading, spacing: 6) {
                TechLabel("Sağlayıcı")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(AIProviderCatalog.all) { info in
                        providerChip(info)
                    }
                }
            }

            Text(model.info.note)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.info.requiresKey {
                keyField
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                    Text("Bu sağlayıcı anahtar istemiyor — her şey Mac'inde çalışıyor.")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(theme.success)
            }

            modelField

            HStack(spacing: 10) {
                Button {
                    Task { await model.test() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isTesting { ProgressView().controlSize(.small) }
                        Text(model.isTesting ? "Test ediliyor…" : "Bağlantıyı test et")
                    }
                }
                .buttonStyle(.atakPrimary)
                .disabled(model.isTesting)

                if let page = model.info.keyPageURL, model.info.requiresKey || model.configuration.providerID == .ollama {
                    Link("Anahtar/kurulum sayfası", destination: URL(string: page)!)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.accent)
                }
                Spacer()
            }

            if let success = model.testSuccess {
                statusLine(success, icon: "checkmark.circle.fill", color: theme.success)
            }
            if let failure = model.testFailure {
                statusLine(failure, icon: "exclamationmark.triangle.fill", color: theme.danger)
            }
            if let notice = model.notice {
                statusLine(notice, icon: "info.circle", color: theme.textSecondary)
            }
            if let raw = model.rawResponse {
                rawResponseBox(raw)
            }
        }
    }

    /// Ayrıştırma başarısız olduğunda sunucudan gelen ham satırlar.
    /// Sorunu tahmine bırakmamak için: ne geldiğini olduğu gibi gösterir.
    private func rawResponseBox(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TechLabel("sunucudan gelen ham yanıt")
                Spacer()
                Button("Kopyala") { model.copyRawResponse() }
                    .buttonStyle(.atakSecondary)
                    .controlSize(.small)
            }

            ScrollView {
                Text(raw)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background {
                RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                    .fill(theme.background.opacity(0.6))
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: theme.hairlineWidth)
            }
        }
    }

    private func providerChip(_ info: AIProviderInfo) -> some View {
        let isSelected = info.id == model.configuration.providerID

        return Button {
            model.selectProvider(info.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(info.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.accent)
                    }
                }
                TechLabel(info.isFree ? "ücretsiz" : "ücretli",
                          color: info.isFree ? theme.success : theme.warning)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel(raised: isSelected, accented: isSelected)
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TechLabel("Model")
                Spacer()
                Button {
                    Task { await model.fetchModels() }
                } label: {
                    HStack(spacing: 5) {
                        if model.isFetchingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise").font(.system(size: 9))
                        }
                        Text(model.isFetchingModels ? "Getiriliyor…" : "Modelleri getir")
                    }
                }
                .buttonStyle(.atakSecondary)
                .controlSize(.small)
                .disabled(model.isFetchingModels)
            }

            HStack(spacing: 8) {
                TextField("model adı", text: $model.modelDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { model.commitModel() }
                Button("Kaydet") { model.commitModel() }
                    .buttonStyle(.atakSecondary)
                    .controlSize(.small)
            }

            if !model.modelOptions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    TechLabel(
                        model.modelOptionsAreLive
                            ? "anahtarına açık modeller (\(model.modelOptions.count))"
                            : "öneriler"
                    )

                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 190), spacing: 6)],
                            spacing: 6
                        ) {
                            ForEach(model.modelOptions, id: \.self) { option in
                                modelChip(option)
                            }
                        }
                    }
                    .frame(maxHeight: model.modelOptionsAreLive ? 150 : 60)
                }
            }

            Text(model.modelOptionsAreLive
                 ? "Bu liste doğrudan sağlayıcıdan geldi — hepsi anahtarınla çalışır."
                 : "Sağlayıcılar model adlarını uyarısız değiştirebiliyor. \"Modelleri getir\" ile anahtarına gerçekten açık olanları görebilirsin.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelChip(_ option: String) -> some View {
        let isSelected = option == model.configuration.model

        return Button {
            model.modelDraft = option
            model.commitModel()
        } label: {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                }
                Text(option)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? theme.accent : theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                .fill(isSelected ? theme.accent.opacity(0.12) : theme.surfaceRaised.opacity(theme.panelOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                .strokeBorder(isSelected ? theme.accent.opacity(0.4) : theme.hairline,
                              lineWidth: theme.hairlineWidth)
        }
        .help(option)
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TechLabel("API anahtarı")
                Spacer()
                if model.hasStoredKey {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.system(size: 9))
                        Text("Keychain'de kayıtlı")
                    }
                    .font(theme.labelFont(size: 10))
                    .foregroundStyle(theme.success)
                }
            }

            HStack(spacing: 8) {
                SecureField(
                    model.hasStoredKey ? "Değiştirmek için yeni anahtarı yapıştır" : "Anahtarı yapıştır",
                    text: $model.apiKeyDraft
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { model.saveKey() }

                Button("Kaydet") { model.saveKey() }
                    .buttonStyle(.atakSecondary)
                    .controlSize(.small)
                    .disabled(model.apiKeyDraft.isEmpty)

                if model.hasStoredKey {
                    Button("Sil", role: .destructive) { model.removeKey() }
                        .controlSize(.small)
                }
            }

            Text("Anahtar yalnızca macOS Keychain'de saklanır; veritabanına, dosyaya veya loga hiçbir zaman yazılmaz.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Görünüm

    private var appearanceSection: some View {
        section("Görünüm") {
            VStack(alignment: .leading, spacing: 8) {
                TechLabel("Tema")
                HStack(spacing: 8) {
                    ForEach(ATAKTheme.Identifier.allCases) { identifier in
                        themeChip(identifier)
                    }
                }
                Text("Sistem açık/koyu moduna her iki tema da uyum sağlar.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func themeChip(_ identifier: ATAKTheme.Identifier) -> some View {
        let candidate = ATAKTheme.theme(for: identifier)
        let isSelected = identifier == environment.themeIdentifier

        return Button {
            environment.updateTheme(identifier)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(candidate.accent).frame(width: 9, height: 9)
                    Text(identifier.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.accent)
                    }
                }
                Text(identifier.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel(raised: isSelected, accented: isSelected)
    }

    // MARK: - Davranış

    private var behaviourSection: some View {
        section("Davranış ve token tüketimi") {
            VStack(alignment: .leading, spacing: 6) {
                TechLabel("Düşünme düzeyi")
                Picker("", selection: Binding(
                    get: { model.configuration.thinkingLevel },
                    set: { model.setThinkingLevel($0) }
                )) {
                    ForEach(ThinkingLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Text(model.configuration.thinkingLevel.note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
                Text("Token tüketiminin en büyük kalemi budur: düşünen modeller kısa bir cevap için bile uzun uzun düşünebiliyor. Yalnız Gemini 3 ailesinde geçerli.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TechLabel("Hatırlanan mesaj sayısı: \(model.configuration.historyLimit)")
                Slider(
                    value: Binding(
                        get: { Double(model.configuration.historyLimit) },
                        set: { model.setHistoryLimit(Int($0)) }
                    ),
                    in: 4...60,
                    step: 2
                )
                Text("Her istekte son bu kadar mesaj gönderilir. Yüksek tutmak ATAK'ın hafızasını uzatır ama her turda daha çok token harcar.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: Binding(
                get: { model.configuration.allowTools },
                set: { model.setAllowTools($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ATAK görev, not ve proje oluşturabilsin")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textPrimary)
                    Text("Kapatırsan ATAK yalnızca konuşur, hiçbir kayıt oluşturmaz.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Toggle(isOn: Binding(
                get: { model.configuration.privateMode },
                set: { model.setPrivateMode($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Özel oturum")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textPrimary)
                    Text("Sohbet metadata dahil diske yazılmaz ve uygulama kapanınca kaybolur. Bulut modeli kullanıyorsan mesajlar yanıt üretmek için sağlayıcıya yine gönderilir; tamamen yerel kullanım için Ollama'yı seç.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Veri

    private var dataSection: some View {
        section("Veri") {
            VStack(alignment: .leading, spacing: 6) {
                TechLabel("Veritabanı")
                Text(Database.defaultURL().path(percentEncoded: false))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.head)
            }

            Button("Finder'da Göster") {
                NSWorkspace.shared.activateFileViewerSelecting([Database.defaultURL()])
            }
            .buttonStyle(.atakSecondary)
            .controlSize(.small)

            Text("Tüm verin bu tek dosyada, senin bilgisayarında. Bulut senkronu yok.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var aboutSection: some View {
        section("Hakkında") {
            row("Sürüm", AppInfo.version)
            row("Paket kimliği", AppInfo.bundleIdentifier)
            row("Durum", environment.agentState.displayName)
        }
    }

    // MARK: - Yardımcılar

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, design: theme.usesTechnicalType ? .monospaced : .default))
                .foregroundStyle(theme.textPrimary)
        }
    }

    private func statusLine(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }
}
