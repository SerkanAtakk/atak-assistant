import SwiftUI

/// Odak zamanlayıcısı ve geçmiş seanslar (spec §24).
struct FocusView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var timer: FocusTimer
    @Environment(\.atakTheme) private var theme
    @StateObject private var model = FocusViewModel()

    private let presets = [15, 25, 45, 60]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(
                    "Odak",
                    subtitle: "Sayaç çalışırken uygulamayı kapatabilirsin; biten seans kaydedilir.",
                    eyebrow: model.todayText,
                    systemImage: "timer"
                )

                dial
                presetRow
                history
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            model.configure(environment)
            await model.load()
        }
        .onChange(of: timer.isRunning) { _, running in
            // Seans bitince geçmiş ve bugünün toplamı tazelenir.
            if !running { Task { await model.load() } }
        }
    }

    // MARK: - Kadran

    private var dial: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(theme.hairline, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: timer.isRunning ? timer.progress : 0)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: timer.progress)

                VStack(spacing: 3) {
                    Text(timer.isRunning ? timer.remainingText : "--:--")
                        .font(theme.numericFont(size: 40, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .monospacedDigit()
                    Text(timer.session?.note.isEmpty == false ? timer.session!.note : "odak")
                        .font(theme.labelFont(size: 10))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 190, height: 190)

            if timer.isRunning {
                Button("Bitir") { timer.stop() }
                    .buttonStyle(.atakSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Süre seç")
            HStack(spacing: 9) {
                ForEach(presets, id: \.self) { minutes in
                    Button("\(minutes) dk") {
                        timer.start(minutes: minutes)
                    }
                    .buttonStyle(.atakSecondary)
                    .disabled(timer.isRunning)
                }
                Spacer()
            }
            Text("Sohbette \"25 dakika odaklan\" da diyebilirsin — ATAK sayacı kendisi başlatır.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: - Geçmiş

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Son seanslar")

            if model.sessions.isEmpty {
                Text("Henüz tamamlanan seans yok.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            } else {
                VStack(spacing: 1) {
                    ForEach(model.sessions) { session in
                        HStack(spacing: 12) {
                            Image(systemName: session.completed ? "checkmark.circle.fill" : "circle.dotted")
                                .font(.system(size: 11))
                                .foregroundStyle(session.completed ? theme.success : theme.textTertiary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.note.isEmpty ? session.kind.displayName : session.note)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textPrimary)
                                Text(DateFormat.relativeDay(session.startedAt))
                                    .font(theme.labelFont(size: 9.5))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                            Text("\(session.actualMinutes ?? 0)/\(session.plannedMinutes) dk")
                                .font(theme.numericFont(size: 11))
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                .panel()
            }
        }
    }
}

/// Odak ekranının verisi. Sayacın kendisi `FocusTimer`'da; burada yalnız
/// geçmiş ve günlük toplam var.
@MainActor
public final class FocusViewModel: ObservableObject {

    @Published public private(set) var sessions: [TimerSession] = []
    @Published public private(set) var minutesToday = 0

    private weak var environment: AppEnvironment?

    public init() {}

    public func configure(_ environment: AppEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment
    }

    public var todayText: String {
        minutesToday == 0 ? "BUGÜN HENÜZ ODAK YOK" : "BUGÜN \(minutesToday) DAKİKA"
    }

    public func load() async {
        guard let service = environment?.timerSessions else { return }
        sessions = (try? await service.recent()) ?? []
        minutesToday = (try? await service.focusedMinutesToday()) ?? 0
    }
}
