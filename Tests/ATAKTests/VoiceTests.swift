import Foundation
import Testing
@testable import ATAKCore

@Suite("Sesli okuma metni")
struct SpeechTextTests {

    @Test("Kalın ve italik işaretleri okunmaz")
    func stripsEmphasis() {
        // Temizlenmezse ATAK "yıldız yıldız önemli yıldız yıldız" der.
        #expect(VoiceService.strippedForSpeech("Bu **önemli** ve _acil_") == "Bu önemli ve acil")
    }

    @Test("Başlık ve alıntı işaretleri düşer")
    func stripsHeadingsAndQuotes() {
        #expect(VoiceService.strippedForSpeech("# Başlık") == "Başlık")
        #expect(VoiceService.strippedForSpeech("> alıntı") == "alıntı")
    }

    @Test("Kod bloğu okunmaz, yerine kısa ifade geçer")
    func replacesCodeBlocks() {
        let spoken = VoiceService.strippedForSpeech("""
        Şöyle yapabilirsin:
        ```swift
        let x = 1
        print(x)
        ```
        Tamam mı?
        """)
        #expect(spoken.contains("kod bloğu"))
        #expect(!spoken.contains("print"))
        #expect(spoken.contains("Tamam mı?"))
    }

    @Test("Satır içi kod işaretleri düşer")
    func stripsInlineCode() {
        #expect(VoiceService.strippedForSpeech("`make run` çalıştır") == "make run çalıştır")
    }

    @Test("Fazla boşluklar sadeleşir")
    func collapsesWhitespace() {
        #expect(VoiceService.strippedForSpeech("çok    fazla     boşluk") == "çok fazla boşluk")
    }

    @Test("Türkçe karakterler korunur")
    func preservesTurkishCharacters() {
        let text = "Çalışmayı **bitirdim**, ığüşöç"
        #expect(VoiceService.strippedForSpeech(text) == "Çalışmayı bitirdim, ığüşöç")
    }

    @Test("Boş veya yalnız işaret içeren metin boş döner")
    func emptyStaysEmpty() {
        #expect(VoiceService.strippedForSpeech("") == "")
        #expect(VoiceService.strippedForSpeech("***") == "")
        #expect(VoiceService.strippedForSpeech("   \n  ") == "")
    }
}

@Suite("Ses ayarları")
struct VoiceSettingsTests {

    @Test("Varsayılanlar açık")
    func defaultsAreOn() {
        #expect(VoiceSettings.default.greetOnLaunch)
        #expect(VoiceSettings.default.speakReplies)
    }

    @Test("Ayarlar gidiş-dönüş kodlanır")
    func roundTrips() throws {
        let settings = VoiceSettings(speakReplies: false, greetOnLaunch: true)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(VoiceSettings.self, from: data) == settings)
    }

    @Test("Küçük harfli hesap adından hitap türetilmez")
    func rejectsLowercaseAccountNames() {
        // Küçük harfli tek parça hesap adları isim değildir; hitapsız kalmak daha iyi.
        #expect(UserIdentity.defaultFirstName().allSatisfy { !$0.isNumber })
    }
}
