import Foundation
import Combine
import AppKit

@MainActor
public final class SettingsViewModel: ObservableObject {

    /// Kullanıcının yazdığı yeni anahtar. Kayıtlı anahtar BURAYA YÜKLENMEZ —
    /// ekranda hiçbir zaman gösterilmez, yalnız "kayıtlı" bilgisi gösterilir.
    @Published public var apiKeyDraft = ""
    @Published public var modelDraft = ""
    @Published public var baseURLDraft = ""
    /// ATAK'ın sana nasıl hitap edeceği.
    @Published public var nameDraft = ""

    @Published public private(set) var hasStoredKey = false
    @Published public private(set) var isTesting = false
    /// Sağlayıcıdan canlı çekilen model listesi (gömülü öneriler yerine geçer).
    @Published public private(set) var fetchedModels: [String] = []
    @Published public private(set) var isFetchingModels = false
    @Published public private(set) var testSuccess: String?
    @Published public private(set) var testFailure: String?
    /// Ayrıştırma başarısız olduğunda sunucudan gelen ham satırlar.
    @Published public private(set) var rawResponse: String?
    @Published public private(set) var notice: String?

    private weak var environment: AppEnvironment?

    public init() {}

    public func configure(_ environment: AppEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment
        syncFromConfiguration()
    }

    public var configuration: AIConfiguration {
        environment?.aiConfiguration ?? .default
    }

    public var info: AIProviderInfo { configuration.info }

    private func syncFromConfiguration() {
        modelDraft = configuration.model
        baseURLDraft = configuration.baseURLOverride ?? ""
        nameDraft = environment?.userName ?? ""
        hasStoredKey = Keychain.has(Keychain.account(for: configuration.providerID))
        apiKeyDraft = ""
        testSuccess = nil
        testFailure = nil
        rawResponse = nil
        fetchedModels = []
    }

    /// Ayarlarda gösterilecek model seçenekleri: canlı liste varsa o, yoksa gömülü öneriler.
    public var modelOptions: [String] {
        fetchedModels.isEmpty ? info.suggestedModels : fetchedModels
    }

    public var modelOptionsAreLive: Bool { !fetchedModels.isEmpty }

    public func fetchModels() async {
        guard let environment else { return }
        isFetchingModels = true
        testFailure = nil
        notice = nil
        defer { isFetchingModels = false }

        switch await environment.fetchAvailableModels() {
        case .success(let models):
            fetchedModels = models
            notice = "\(models.count) model bulundu. Aşağıdan seçebilirsin."
        case .failure(let error):
            testFailure = error.localizedDescription
        }
    }

    // MARK: - Değişiklikler

    public func selectProvider(_ id: AIProviderID) {
        guard let environment, id != configuration.providerID else { return }
        environment.updateConfiguration(configuration.switching(to: id))
        syncFromConfiguration()
        notice = nil
    }

    public func saveKey() {
        guard let environment else { return }
        do {
            try Keychain.set(apiKeyDraft, for: Keychain.account(for: configuration.providerID))
            apiKeyDraft = ""
            hasStoredKey = Keychain.has(Keychain.account(for: configuration.providerID))
            notice = hasStoredKey ? "Anahtar Keychain'e kaydedildi." : "Anahtar silindi."
            testSuccess = nil
            testFailure = nil
            // Yapılandırma değişmedi ama "hazır mı" durumu değişti; UI tazelensin.
            environment.updateConfiguration(configuration)
        } catch {
            testFailure = error.localizedDescription
        }
    }

    public func removeKey() {
        guard let environment else { return }
        try? Keychain.remove(Keychain.account(for: configuration.providerID))
        hasStoredKey = false
        notice = "Anahtar silindi."
        environment.updateConfiguration(configuration)
    }

    public func commitModel() {
        guard let environment else { return }
        let trimmed = modelDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            modelDraft = configuration.model
            return
        }
        var updated = configuration
        updated.model = trimmed
        environment.updateConfiguration(updated)
        notice = "Model güncellendi."
    }

    public func commitBaseURL() {
        guard let environment else { return }
        let custom = baseURLDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        do {
            _ = try AIProviderCatalog.validatedBaseURL(
                for: configuration.providerID,
                override: custom
            )
            var updated = configuration
            updated.baseURLOverride = custom
            environment.updateConfiguration(updated)
            baseURLDraft = custom ?? ""
            testFailure = nil
            notice = custom == nil ? "Varsayılan sunucu adresi kullanılıyor." : "Sunucu adresi güncellendi."
        } catch {
            baseURLDraft = configuration.baseURLOverride ?? ""
            notice = nil
            testFailure = error.localizedDescription
        }
    }

    public func setAllowTools(_ value: Bool) {
        guard let environment else { return }
        var updated = configuration
        updated.allowTools = value
        environment.updateConfiguration(updated)
    }

    public func setThinkingLevel(_ level: ThinkingLevel) {
        guard let environment else { return }
        var updated = configuration
        updated.thinkingLevel = level
        environment.updateConfiguration(updated)
    }

    public func setHistoryLimit(_ limit: Int) {
        guard let environment, limit != configuration.historyLimit else { return }
        var updated = configuration
        updated.historyLimit = limit
        environment.updateConfiguration(updated)
    }

    public func setPrivateMode(_ value: Bool) {
        guard let environment else { return }
        var updated = configuration
        updated.privateMode = value
        environment.updateConfiguration(updated)
    }

    // MARK: - Kişisel & ses

    public var voiceSettings: VoiceSettings { environment?.voiceSettings ?? .default }

    public func commitName() {
        environment?.updateUserName(nameDraft)
        notice = nameDraft.isEmpty ? "Hitap kaldırıldı." : "ATAK sana \"\(nameDraft)\" diyecek."
    }

    public func setSpeakReplies(_ value: Bool) {
        var updated = voiceSettings
        updated.speakReplies = value
        environment?.updateVoiceSettings(updated)
    }

    public func setGreetOnLaunch(_ value: Bool) {
        var updated = voiceSettings
        updated.greetOnLaunch = value
        environment?.updateVoiceSettings(updated)
    }

    /// Sesi ve izinleri tek tıkla dener.
    public func testVoice() async {
        guard let environment else { return }
        let granted = await environment.voice.requestAuthorization()
        if granted {
            environment.voice.speak(environment.greeting)
            notice = "Sesi duyuyorsan her şey hazır."
        } else {
            testFailure = environment.voice.availability.message ?? "Ses izni alınamadı."
        }
    }

    // MARK: - Test

    public func test() async {
        guard let environment else { return }
        isTesting = true
        testSuccess = nil
        testFailure = nil
        notice = nil
        defer { isTesting = false }

        rawResponse = nil
        let result = await environment.testConnection()

        if result.succeeded {
            testSuccess = "Bağlantı çalışıyor. Model yanıtı: \"\(result.message.prefix(80))\""
        } else {
            testFailure = result.message
            rawResponse = result.rawResponse
        }
    }

    public func copyRawResponse() {
        guard let rawResponse else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawResponse, forType: .string)
        notice = "Ham yanıt panoya kopyalandı."
    }
}
