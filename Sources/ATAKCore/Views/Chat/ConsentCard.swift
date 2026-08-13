import SwiftUI

/// Riskli bir işlemden önce çıkan onay kartı (MIMARI §8).
///
/// Tasarım kararları güvenlik kararlarıdır, süs değil:
/// - Varsayılan buton **İptal**; Enter'a refleksle basan kullanıcı işlemi
///   onaylamış olmaz.
/// - "Bir daha sorma" seçeneği yok.
/// - Risk seviyesi ve geri alınabilirlik açıkça yazılır; kullanıcı neyi
///   onayladığını görmeden onaylayamaz.
struct ConsentCard: View {

    let request: ConsentRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    @Environment(\.atakTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(riskColor)
                Text("ATAK bu işlem için onayını istiyor")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                riskBadge
            }

            Text(request.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !request.rationale.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    TechLabel("ATAK'IN NEDENİ")
                    Text(request.rationale)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !request.assessment.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(request.assessment.reasons, id: \.self) { reason in
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.warning)
                    }
                }
            }

            if !request.affected.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    TechLabel("ETKİLENECEKLER (\(request.affected.count))")
                    ForEach(request.affected.prefix(8), id: \.self) { item in
                        Text("· \(item)")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                // Varsayılan eylem bilinçli olarak İPTAL: Enter'a basmak
                // riskli işlemi onaylamamalı.
                Button("İptal", action: onDeny)
                    .buttonStyle(ATAKSecondaryButtonStyle())
                    .keyboardShortcut(.defaultAction)

                Button("Onayla", action: onApprove)
                    .buttonStyle(ATAKPrimaryButtonStyle())
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .fill(theme.surfaceRaised.opacity(theme.panelOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .strokeBorder(riskColor.opacity(0.5), lineWidth: 1)
        )
    }

    private var riskBadge: some View {
        Text(request.assessment.level.displayName.uppercased())
            .font(theme.labelFont(size: 9))
            .foregroundStyle(riskColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(riskColor.opacity(0.12), in: Capsule())
    }

    private var riskColor: Color {
        switch request.assessment.level {
        case .low:    return theme.accent
        case .medium: return theme.warning
        case .high:   return theme.danger
        }
    }
}
