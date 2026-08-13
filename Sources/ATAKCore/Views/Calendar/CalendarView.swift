import SwiftUI
import AppKit

/// Önümüzdeki haftanın takvimi ve bugünün boş aralıkları.
///
/// ATAK takvime yalnız **okumak** için serbestçe bakar; etkinlik oluşturma
/// sohbette onay kartından geçer (MIMARI §5).
struct CalendarView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.atakTheme) private var theme
    @StateObject private var model = CalendarViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenHeader(
                    "Takvim",
                    subtitle: "Önümüzdeki \(model.horizon) gün. ATAK bu bilgiyi plan yaparken kullanır.",
                    eyebrow: "SONRAKİ 7 GÜN",
                    systemImage: "calendar"
                )

                if let error = model.errorMessage {
                    InlineNotice("Takvim okunamadı", message: error, kind: .warning)
                }

                if !model.accessGranted {
                    permissionPanel
                } else {
                    freeSlotsPanel
                    if model.days.isEmpty && !model.isLoading {
                        Text("Önümüzdeki \(model.horizon) günde takvimde etkinlik yok.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        ForEach(model.days) { day in
                            daySection(day)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            model.configure(environment)
            await model.load()
        }
    }

    // MARK: - İzin

    private var permissionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ATAK takvimini görmüyor")
                .font(theme.titleFont(size: 15))
                .foregroundStyle(theme.textPrimary)
            Text(Permission.calendar.rationale)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isPermanentlyDenied {
                // İzin bir kez reddedildiyse macOS tekrar sormamıza izin
                // vermez; kullanıcıyı doğrudan doğru panele götürüyoruz.
                Text(Permission.calendar.settingsHint ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.warning)
                Button("Sistem Ayarları'nı aç") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.atakSecondary)
            } else {
                Button("Takvim erişimine izin ver") {
                    Task { await model.requestAccess() }
                }
                .buttonStyle(.atakPrimary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - Boş aralıklar

    @ViewBuilder
    private var freeSlotsPanel: some View {
        if !model.freeSlots.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                TechLabel("BUGÜN BOŞ ARALIKLAR", color: theme.accent)
                HStack(spacing: 7) {
                    ForEach(model.freeSlots, id: \.self) { slot in
                        Text(slot)
                            .font(theme.numericFont(size: 11))
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(theme.accent.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    // MARK: - Gün

    private func daySection(_ day: CalendarViewModel.Day) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(DateFormat.relativeDay(day.date))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(DateFormat.weekday(day.date))
                    .font(theme.labelFont(size: 10))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Text("\(day.events.count) etkinlik")
                    .font(theme.labelFont(size: 9.5))
                    .foregroundStyle(theme.textTertiary)
            }

            VStack(spacing: 1) {
                ForEach(day.events) { event in
                    HStack(spacing: 12) {
                        Text(event.isAllDay ? "tüm gün" : DateFormat.time(event.startsAt))
                            .font(theme.numericFont(size: 11.5))
                            .foregroundStyle(theme.accent)
                            .frame(width: 62, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.system(size: 12.5))
                                .foregroundStyle(theme.textPrimary)
                            if !event.location.isEmpty {
                                Text(event.location)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        Spacer()
                        Text(event.calendarName)
                            .font(theme.labelFont(size: 9))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .panel()
        }
    }
}
