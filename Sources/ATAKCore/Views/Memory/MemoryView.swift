import SwiftUI

/// ATAK'ın kullanıcı hakkında bildikleri ve yaptıklarının defteri.
///
/// İki yarı: **Hafıza** (ne biliyor) ve **Etkinlik** (ne yaptı). İkisi de
/// kullanıcı tarafından görülebilir ve silinebilir olmalı — göremediğin bir
/// hafıza ve hesabı sorulamayan bir eylem, asistanı kara kutuya çevirir.
struct MemoryView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.atakTheme) private var theme
    @StateObject private var model = MemoryViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(
                    "ATAK Hafızası",
                    subtitle: "ATAK'ın senin hakkında hatırladıkları ve yaptığı işler. Hepsi bu Mac'te, hepsi silinebilir.",
                    eyebrow: "KİŞİSEL VERİ",
                    systemImage: "brain"
                )

                if let error = model.errorMessage {
                    InlineNotice("Bir sorun oluştu", message: error, kind: .error)
                }

                undoStrip
                composer
                memoryList
                activityList
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            model.configure(environment)
            await model.load()
        }
        .onChange(of: model.searchText) { _, _ in
            Task { await model.load() }
        }
    }

    // MARK: - Geri alma

    @ViewBuilder
    private var undoStrip: some View {
        if let candidate = model.undoCandidate, let token = candidate.undo {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward")
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Son işlem geri alınabilir")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(token.undoDescription)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Button("Geri al") {
                    Task { await model.undoLast() }
                }
                .buttonStyle(.atakSecondary)
            }
            .padding(14)
            .panel()
        }
    }

    // MARK: - Yeni kayıt

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Bilgi ekle")
            HStack(spacing: 9) {
                TextField("Konu — örn. spor günleri", text: $model.draftKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                TextField("Bilgi — örn. salı ve perşembe", text: $model.draftValue)
                    .textFieldStyle(.roundedBorder)
                Button("Kaydet") {
                    Task { await model.add() }
                }
                .buttonStyle(.atakPrimary)
                .disabled(model.draftKey.isEmpty || model.draftValue.isEmpty)
            }
            Text("Aynı konuda yeni bir bilgi eklersen eskisi geçersiz sayılır, silinmez.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: - Hafıza listesi

    private var memoryList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Hatırlananlar")
                Spacer()
                TextField("Ara", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            if model.isEmpty {
                Text("ATAK henüz senin hakkında bir şey hatırlamıyor. Sohbette \"bunu hatırla\" dediğinde buraya eklenir.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 1) {
                    ForEach(model.items) { item in
                        memoryRow(item)
                    }
                }
                .panel()
            }
        }
    }

    private func memoryRow(_ item: MemoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await model.togglePinned(item) }
            } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(item.pinned ? theme.accent : theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(item.pinned ? "Sabitlemeyi kaldır" : "Sabitle — her sohbette gönderilir")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.key)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Text(item.value)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text(item.kind.displayName)
                .font(theme.labelFont(size: 9))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(theme.surface, in: Capsule())

            Button {
                Task { await model.forget(item) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Unut")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Etkinlik defteri

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("ATAK ne yaptı")
                Spacer()
                if !model.actions.isEmpty {
                    Button("Geçmişi temizle") {
                        Task { await model.clearHistory() }
                    }
                    .buttonStyle(.atakSecondary)
                }
            }

            Text("Sohbetteki cümleler modelin iddiasıdır; bu liste gerçekte çalışan işlemlerdir.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)

            if model.actions.isEmpty {
                Text("Henüz kayıtlı işlem yok.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 1) {
                    ForEach(model.actions) { action in
                        actionRow(action)
                    }
                }
                .panel()
            }
        }
    }

    private func actionRow(_ action: AssistantAction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon(action.status))
                .font(.system(size: 11))
                .foregroundStyle(statusColor(action.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(ChatEngine.friendlyName(action.toolID))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                if !action.summary.isEmpty {
                    Text(action.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                if let error = action.error {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.danger)
                        .lineLimit(2)
                }
            }

            Spacer()

            if action.requiredConsent {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.warning)
                    .help("Bu işlem senin onayınla yapıldı")
            }

            Text(action.risk.displayName)
                .font(theme.labelFont(size: 9))
                .foregroundStyle(theme.textTertiary)

            Text(DateFormat.relativeDay(action.startedAt))
                .font(theme.labelFont(size: 9))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statusIcon(_ status: ActionStatus) -> String {
        switch status {
        case .succeeded: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .denied:    return "hand.raised.fill"
        case .cancelled: return "arrow.uturn.backward.circle.fill"
        }
    }

    private func statusColor(_ status: ActionStatus) -> Color {
        switch status {
        case .succeeded: return theme.success
        case .failed:    return theme.danger
        case .denied:    return theme.warning
        case .cancelled: return theme.textTertiary
        }
    }
}
