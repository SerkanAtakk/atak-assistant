import SwiftUI
import AppKit

// MARK: - Dinamik renk yardımcısı

extension Color {
    /// Açık/koyu moda göre otomatik değişen renk.
    ///
    /// `NSColor` dinamik sağlayıcısı kullanılır; böylece tek bir `Color` değeri
    /// her iki temada da doğru görünür ve görünümlerin `colorScheme` okumasına
    /// gerek kalmaz.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static func hex(_ value: UInt32) -> Color {
        Color(nsColor: NSColor(hex: value))
    }
}

extension NSColor {
    /// 0xRRGGBB veya 0xAARRGGBB
    convenience init(hex: UInt32) {
        let hasAlpha = hex > 0xFF_FF_FF
        let alpha = hasAlpha ? CGFloat((hex >> 24) & 0xFF) / 255 : 1
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Tema

/// ATAK'ın tüm görsel kararlarının tek kaynağı.
///
/// Renk, yarıçap, çizgi kalınlığı ve tipografi seçimleri burada toplanır;
/// hiçbir görünüm doğrudan renk sabiti kullanmaz. İki tema (HUD ve Minimal)
/// bu yapının iki örneğidir — yeni tema eklemek yeni bir `static let` demektir.
public struct ATAKTheme: Sendable, Equatable, Identifiable {

    public enum Identifier: String, Sendable, CaseIterable, Codable, Identifiable {
        case hud
        case minimal

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .hud:     return "ATAK HUD"
            case .minimal: return "Minimal"
            }
        }

        public var summary: String {
            switch self {
            case .hud:     return "Koyu zemin, turkuaz vurgu, teknik tipografi"
            case .minimal: return "Sakin nötr zemin, indigo vurgu, geniş boşluk"
            }
        }
    }

    public let identifier: Identifier
    public var id: String { identifier.rawValue }

    // Zeminler
    public let background: Color
    public let surface: Color
    public let surfaceRaised: Color

    // Vurgu
    public let accent: Color
    public let accentMuted: Color

    // Metin
    public let textPrimary: Color
    public let textSecondary: Color
    public let textTertiary: Color

    // Anlamsal
    public let success: Color
    public let warning: Color
    public let danger: Color

    // Çizgi & şekil
    public let hairline: Color
    public let hairlineWidth: CGFloat
    public let cornerRadius: CGFloat
    public let cornerRadiusTight: CGFloat

    // Karakter
    /// Etiket ve sayılarda monospace kullanılsın mı (HUD'un "teknik" hissi).
    public let usesTechnicalType: Bool
    /// Zeminde ince grid dokusu çizilsin mi.
    public let showsGrid: Bool
    /// Vurgu öğelerinin etrafındaki ışıma yarıçapı (0 = kapalı).
    public let glow: CGFloat
    /// Panel dolgusunun opaklığı.
    public let panelOpacity: Double

    // MARK: Tipografi yardımcıları

    /// Küçük teknik etiket (durum, birim, sayaç).
    public func labelFont(size: CGFloat = 11) -> Font {
        usesTechnicalType
            ? .system(size: size, weight: .medium, design: .monospaced)
            : .system(size: size, weight: .medium)
    }

    /// Sayılar — her iki temada da hizalı kalsın diye monospaced rakam.
    public func numericFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: usesTechnicalType ? .monospaced : .rounded)
    }

    public func titleFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: - HUD

    /// Spec §46'daki "ATAK HUD": futuristik ama okunabilirlikten ödün vermeyen.
    public static let hud = ATAKTheme(
        identifier: .hud,
        background:     .adaptive(light: 0xEEF2F4, dark: 0x07090D),
        surface:        .adaptive(light: 0xFFFFFF, dark: 0x0E1319),
        surfaceRaised:  .adaptive(light: 0xF7FAFB, dark: 0x151C24),
        accent:         .adaptive(light: 0x0C8C7E, dark: 0x3DDCC8),
        accentMuted:    .adaptive(light: 0x7FC6BC, dark: 0x1C6F65),
        textPrimary:    .adaptive(light: 0x0B1418, dark: 0xE6F1F3),
        textSecondary:  .adaptive(light: 0x4A5B62, dark: 0x8FA3AC),
        textTertiary:   .adaptive(light: 0x8496A0, dark: 0x55666F),
        success:        .adaptive(light: 0x0E8A5F, dark: 0x3FD99B),
        warning:        .adaptive(light: 0xA86A00, dark: 0xF2B25C),
        danger:         .adaptive(light: 0xC0392B, dark: 0xFF6B6B),
        hairline:       .adaptive(light: 0xD3DDE1, dark: 0x1E2A33),
        hairlineWidth: 1,
        cornerRadius: 10,
        cornerRadiusTight: 6,
        usesTechnicalType: true,
        showsGrid: true,
        glow: 12,
        panelOpacity: 0.65
    )

    // MARK: - Minimal

    /// Sakin, yüksek kontrastlı, "premium araç" hissi.
    public static let minimal = ATAKTheme(
        identifier: .minimal,
        background:     .adaptive(light: 0xF6F6F7, dark: 0x0E0E11),
        surface:        .adaptive(light: 0xFFFFFF, dark: 0x17171B),
        surfaceRaised:  .adaptive(light: 0xFBFBFC, dark: 0x1F1F25),
        accent:         .adaptive(light: 0x5A4FE0, dark: 0x8B82FF),
        accentMuted:    .adaptive(light: 0xB5AFF2, dark: 0x413A87),
        textPrimary:    .adaptive(light: 0x16161A, dark: 0xF2F2F5),
        textSecondary:  .adaptive(light: 0x5C5C66, dark: 0x9B9BA6),
        textTertiary:   .adaptive(light: 0x8E8E99, dark: 0x63636E),
        success:        .adaptive(light: 0x1B8A50, dark: 0x4ED18A),
        warning:        .adaptive(light: 0xB0740C, dark: 0xE8B15A),
        danger:         .adaptive(light: 0xC7362C, dark: 0xF87171),
        hairline:       .adaptive(light: 0xE3E3E7, dark: 0x2A2A31),
        hairlineWidth: 1,
        cornerRadius: 12,
        cornerRadiusTight: 8,
        usesTechnicalType: false,
        showsGrid: false,
        glow: 0,
        panelOpacity: 1.0
    )

    public static func theme(for identifier: Identifier) -> ATAKTheme {
        switch identifier {
        case .hud:     return .hud
        case .minimal: return .minimal
        }
    }
}

// MARK: - Ortam anahtarı

private struct ATAKThemeKey: EnvironmentKey {
    static let defaultValue: ATAKTheme = .hud
}

extension EnvironmentValues {
    public var atakTheme: ATAKTheme {
        get { self[ATAKThemeKey.self] }
        set { self[ATAKThemeKey.self] = newValue }
    }
}
