import Foundation
import Combine
import EventKit

/// Takvim ekranı: önümüzdeki günlerin etkinlikleri ve boş aralıklar.
@MainActor
public final class CalendarViewModel: ObservableObject {

    public struct Day: Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        public let events: [CalendarEvent]
    }

    @Published public private(set) var days: [Day] = []
    @Published public private(set) var freeSlots: [String] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var accessGranted = false
    @Published public var errorMessage: String?

    private weak var environment: AppEnvironment?

    /// Kaç gün ileriye bakılıyor.
    public let horizon = 7

    public init() {}

    public func configure(_ environment: AppEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment
        accessGranted = environment.calendar.hasAccess
    }

    public func load() async {
        guard let calendar = environment?.calendar else { return }
        accessGranted = calendar.hasAccess
        guard accessGranted else { return }

        isLoading = true
        defer { isLoading = false }

        let bounds = TaskService.todayBounds()
        let end = Calendar.current.date(byAdding: .day, value: horizon, to: bounds.start)
            ?? bounds.start.addingTimeInterval(Double(horizon) * 86_400)

        do {
            let events = try await calendar.events(from: bounds.start, to: end)

            // Etkinlikler güne göre gruplanır; boş günler listede görünmez.
            let grouped = Dictionary(grouping: events) {
                Calendar.current.startOfDay(for: $0.startsAt)
            }
            days = grouped.keys.sorted().map { Day(date: $0, events: grouped[$0] ?? []) }

            let dayStart = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: bounds.start) ?? bounds.start
            let dayEnd = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: bounds.start) ?? bounds.end
            freeSlots = try await calendar.freeSlots(from: dayStart, to: dayEnd)
                .map { "\(DateFormat.time($0.start))–\(DateFormat.time($0.end))" }

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func requestAccess() async {
        guard let calendar = environment?.calendar else { return }
        do {
            accessGranted = try await calendar.requestAccess()
            if accessGranted { await load() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// İzin bir kez reddedildiyse uygulama tekrar soramaz — kullanıcıya
    /// Sistem Ayarları'na gitmesi gerektiği söylenir.
    public var isPermanentlyDenied: Bool {
        environment?.calendar.authorizationStatus == .denied
    }
}
