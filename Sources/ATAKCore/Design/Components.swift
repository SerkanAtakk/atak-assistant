import SwiftUI

// MARK: - Zemin

/// Uygulama zemini: taban rengi + (HUD'da) çok düşük opaklıkta grid dokusu
/// ve üstte hafif bir vurgu ışıması.
///
/// Grid `Canvas` ile çizilir ve yalnızca boyut değiştiğinde yeniden çizilir —
/// sürekli animasyon yok (spec §47: düşük CPU).
struct ATAKBackground: ViewModifier {
    @Environment(\.atakTheme) private var theme

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                theme.background

                if theme.showsGrid {
                    Canvas { context, size in
                        let step: CGFloat = 28
                        var path = Path()
                        var x: CGFloat = 0
                        while x < size.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                            x += step
                        }
                        var y: CGFloat = 0
                        while y < size.height {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                            y += step
                        }
                        context.stroke(path, with: .color(theme.accent.opacity(0.045)), lineWidth: 0.5)
                    }
                    .allowsHitTesting(false)

                    // Üstten aşağı çok hafif vurgu ışıması
                    LinearGradient(
                        colors: [theme.accent.opacity(0.06), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    func atakBackground() -> some View { modifier(ATAKBackground()) }
}

// MARK: - Panel

/// Kart/panel yüzeyi: yüzey rengi + ince kenar çizgisi + temaya göre yuvarlaklık.
struct PanelSurface: ViewModifier {
    @Environment(\.atakTheme) private var theme
    var raised: Bool = false
    var accented: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .fill((raised ? theme.surfaceRaised : theme.surface).opacity(theme.panelOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .strokeBorder(
                        accented ? theme.accent.opacity(0.45) : theme.hairline,
                        lineWidth: theme.hairlineWidth
                    )
            }
            .shadow(
                color: accented && theme.glow > 0 ? theme.accent.opacity(0.22) : .clear,
                radius: theme.glow
            )
    }
}

extension View {
    func panel(raised: Bool = false, accented: Bool = false) -> some View {
        modifier(PanelSurface(raised: raised, accented: accented))
    }
}

// MARK: - Ayraç

struct Hairline: View {
    @Environment(\.atakTheme) private var theme
    var body: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(height: theme.hairlineWidth)
    }
}

// MARK: - Teknik etiket

/// Küçük büyük-harf etiket. HUD'da monospace + harf aralığı, Minimal'de sade.
struct TechLabel: View {
    @Environment(\.atakTheme) private var theme
    let text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(theme.usesTechnicalType ? text.uppercased(with: DateFormat.locale) : text)
            .font(theme.labelFont())
            .tracking(theme.usesTechnicalType ? 0.8 : 0)
            .foregroundStyle(color ?? theme.textTertiary)
    }
}

// MARK: - Durum göstergesi (spec §45)

struct StatusIndicator: View {
    @Environment(\.atakTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: AgentState
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            dot
            if !compact {
                TechLabel(state.displayName, color: theme.textSecondary)
            }
        }
        .help(state.displayName)
    }

    @ViewBuilder
    private var dot: some View {
        let color = tint

        if state.isBusy && !reduceMotion {
            // Yalnızca meşgulken animasyon çalışır; boştayken hiç CPU harcanmaz.
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .phaseAnimator([0.35, 1.0]) { view, phase in
                    view.opacity(phase)
                        .shadow(color: theme.glow > 0 ? color.opacity(phase * 0.9) : .clear,
                                radius: theme.glow * 0.7)
                } animation: { _ in
                    .easeInOut(duration: 0.75)
                }
        } else {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: theme.glow > 0 ? color.opacity(0.6) : .clear, radius: theme.glow * 0.5)
        }
    }

    private var tint: Color {
        switch state {
        case .ready:            return theme.success
        case .offline:          return theme.textTertiary
        case .awaitingConsent:  return theme.warning
        case .error:            return theme.danger
        default:                return theme.accent
        }
    }
}

// MARK: - Marka ve ekran başlığı

/// Uygulama içinde kullanılan küçük ATAK işareti. Paket simgesinin yerine
/// geçmez; sidebar ve kurulum ekranlarında aynı görsel dili taşır.
struct ATAKLogoMark: View {
    @Environment(\.atakTheme) private var theme
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.accent.opacity(0.95), theme.accentMuted],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.43, weight: .bold))
                .foregroundStyle(theme.background)
        }
        .frame(width: size, height: size)
        .shadow(color: theme.accent.opacity(theme.glow > 0 ? 0.3 : 0.12), radius: max(4, theme.glow * 0.55))
        .accessibilityHidden(true)
    }
}

struct ScreenHeader: View {
    @Environment(\.atakTheme) private var theme
    let eyebrow: String?
    let title: String
    let subtitle: String?
    let systemImage: String?

    init(
        _ title: String,
        subtitle: String? = nil,
        eyebrow: String? = nil,
        systemImage: String? = nil
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 36, height: 36)
                    .background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow { TechLabel(eyebrow, color: theme.accent) }
                Text(title)
                    .font(theme.titleFont(size: 27, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct SectionTitle: View {
    @Environment(\.atakTheme) private var theme
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(theme.titleFont(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if let detail {
                Text(detail)
                    .font(theme.labelFont(size: 10.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }
}

struct InlineNotice: View {
    enum Kind { case info, success, warning, error }

    @Environment(\.atakTheme) private var theme
    let kind: Kind
    let title: String
    let message: String?

    init(_ title: String, message: String? = nil, kind: Kind = .info) {
        self.kind = kind
        self.title = title
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: theme.hairlineWidth)
        }
    }

    private var icon: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: return theme.accent
        case .success: return theme.success
        case .warning: return theme.warning
        case .error: return theme.danger
        }
    }
}

// MARK: - Butonlar

struct ATAKPrimaryButtonStyle: ButtonStyle {
    @Environment(\.atakTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.background)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                    .fill(theme.accent.opacity(isEnabled ? 1 : 0.35))
            }
            .shadow(
                color: theme.glow > 0 && isEnabled ? theme.accent.opacity(0.35) : .clear,
                radius: theme.glow * 0.8
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct ATAKSecondaryButtonStyle: ButtonStyle {
    @Environment(\.atakTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? theme.textPrimary : theme.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                    .fill(theme.surfaceRaised.opacity(theme.panelOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.cornerRadiusTight, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: theme.hairlineWidth)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension ButtonStyle where Self == ATAKPrimaryButtonStyle {
    static var atakPrimary: ATAKPrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == ATAKSecondaryButtonStyle {
    static var atakSecondary: ATAKSecondaryButtonStyle { .init() }
}

// MARK: - Boş durum

struct EmptyStateView: View {
    @Environment(\.atakTheme) private var theme
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text(title)
                .font(theme.titleFont(size: 16))
                .foregroundStyle(theme.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.atakPrimary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Akış yerleşimi

/// Çip ve kısa kart listelerini genişlik varsa tek satırda, yoksa yatay
/// kaydırmada tutar. İçerik kesilmez ve dar pencerelerde taşma üretmez.
struct FlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(items) { content($0) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { content($0) }
                }
            }
        }
    }
}
