import Foundation
import AVFoundation
import Speech
import Combine

/// Sesli giriş (konuşma → metin) ve sesli çıkış (metin → konuşma).
///
/// Spec §26: varsayılan bas-konuş; sürekli dinleme kapalı. Mikrofon yalnız
/// kullanıcı başlattığında açılır ve durdurulduğunda hemen kapanır.
@MainActor
public final class VoiceService: ObservableObject {

    public enum Availability: Equatable {
        case ready
        case needsPermission
        case denied(String)
        case unsupported(String)
    }

    @Published public private(set) var isListening = false
    @Published public private(set) var isSpeaking = false
    /// Konuşurken canlı güncellenen metin.
    @Published public private(set) var transcript = ""
    @Published public private(set) var availability: Availability = .needsPermission
    @Published public var errorMessage: String?

    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechDelegate: SpeechDelegate?

    /// Dinleme bittiğinde son metinle çağrılır (boşsa çağrılmaz).
    public var onFinalTranscript: ((String) -> Void)?

    public init() {
        let delegate = SpeechDelegate()
        delegate.onChange = { [weak self] speaking in
            Task { @MainActor in self?.isSpeaking = speaking }
        }
        synthesizer.delegate = delegate
        speechDelegate = delegate
    }

    // MARK: - İzinler

    /// Mikrofon ve konuşma tanıma izinlerini ister.
    ///
    /// İzin kullanım anında istenir (MIMARI §7) — onboarding'de toplu değil.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        guard SFSpeechRecognizer(locale: Self.locale) != nil else {
            availability = .unsupported(
                "Bu Mac'te Türkçe konuşma tanıma bulunamadı. Sistem Ayarları → Klavye → Dikte'den Türkçe'yi ekleyebilirsin."
            )
            return false
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }

        guard speechStatus == .authorized else {
            availability = .denied(
                "Konuşma tanıma izni verilmedi. Sistem Ayarları → Gizlilik ve Güvenlik → Konuşma Tanıma'dan ATAK'a izin verebilirsin."
            )
            return false
        }

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            availability = .denied(
                "Mikrofon izni verilmedi. Sistem Ayarları → Gizlilik ve Güvenlik → Mikrofon'dan ATAK'a izin verebilirsin."
            )
            return false
        }

        availability = .ready
        return true
    }

    // MARK: - Dinleme

    public func toggleListening() async {
        if isListening {
            stopListening()
        } else {
            await startListening()
        }
    }

    public func startListening() async {
        guard !isListening else { return }

        if availability != .ready {
            guard await requestAuthorization() else {
                errorMessage = availability.message
                return
            }
        }

        // ATAK konuşuyorsa sussun — kendi sesini dinlemesin.
        stopSpeaking()

        guard let recognizer = SFSpeechRecognizer(locale: Self.locale), recognizer.isAvailable else {
            errorMessage = "Konuşma tanıma şu anda kullanılamıyor."
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Mümkünse cihazda çalışsın: ses Apple sunucularına gitmez.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.channelCount > 0 else {
            errorMessage = "Mikrofon girişi bulunamadı."
            return
        }

        // Ses geri çağrısı gerçek zamanlı ses iş parçacığında çalışır; istek
        // nesnesi oraya bilinçli olarak taşınıyor (Apple'ın belgelediği kullanım).
        let box = RequestBox(request)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.request.append(buffer)
        }

        transcript = ""
        errorMessage = nil

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stopListening()
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isListening = true
            Log.app.info("Dinleme başladı")
        } catch {
            cleanUpAudio()
            errorMessage = "Mikrofon başlatılamadı: \(error.localizedDescription)"
        }
    }

    public func stopListening() {
        guard isListening || engine.isRunning else { return }

        cleanUpAudio()
        isListening = false

        let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        if !finalText.isEmpty {
            onFinalTranscript?(finalText)
        }
    }

    private func cleanUpAudio() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
    }

    // MARK: - Konuşma

    public func speak(_ text: String) {
        let cleaned = Self.strippedForSpeech(text)
        guard !cleaned.isEmpty else {
            Log.app.info("speak: temizlikten sonra metin boş kaldı, okunmadı")
            return
        }

        stopSpeaking()

        let voice = Self.preferredVoice()
        Log.app.info(
            "speak: \(cleaned.count) karakter, ses=\(voice?.name ?? "YOK", privacy: .public)"
        )

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    public func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    // MARK: - Yardımcılar

    static let locale = Locale(identifier: "tr-TR")

    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        // Gelişmiş/premium Türkçe ses varsa onu seç — varsayılan sesten çok daha doğal.
        let turkish = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("tr") }

        return turkish.first { $0.quality == .premium }
            ?? turkish.first { $0.quality == .enhanced }
            ?? turkish.first
            ?? AVSpeechSynthesisVoice(language: "tr-TR")
    }

    /// Markdown işaretlerini sesli okumadan önce temizler.
    ///
    /// Aksi hâlde ATAK "yıldız yıldız önemli yıldız yıldız" diye okur.
    /// Saf bir dönüşüm olduğu için aktör izolasyonuna gerek yok — test
    /// edilebilir kalsın diye `nonisolated`.
    nonisolated static func strippedForSpeech(_ text: String) -> String {
        var result = text

        // Kod blokları hiç okunmasın.
        result = result.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " kod bloğu ",
            options: .regularExpression
        )

        for token in ["**", "__", "*", "_", "`", "#", ">"] {
            result = result.replacingOccurrences(of: token, with: "")
        }

        // Liste tireleri ve fazla boşluk
        result = result.replacingOccurrences(
            of: "^[\\-•]\\s*",
            with: "",
            options: [.regularExpression]
        )
        result = result.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ses geri çağrısına taşınan tanıma isteği için güvenli sarmalayıcı.
    private final class RequestBox: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    }

    /// Konuşma bitişini izler.
    private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        var onChange: ((Bool) -> Void)?

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            onChange?(false)
        }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            onChange?(false)
        }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            onChange?(true)
        }
    }
}

extension VoiceService.Availability {
    var message: String? {
        switch self {
        case .ready, .needsPermission:       return nil
        case .denied(let text):              return text
        case .unsupported(let text):         return text
        }
    }
}
