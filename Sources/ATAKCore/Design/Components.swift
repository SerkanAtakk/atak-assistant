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

        if state.isBusy {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
