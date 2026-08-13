import Foundation
import EventKit

/// Takvimden okunan tek bir etkinlik.
///
/// `EKEvent` bir sınıf ve `Sendable` değil; aktörün dışına asla çıkmaz,
/// dışarıya yalnız bu değer tipi verilir (veritabanı katmanıyla aynı kural).
public struct CalendarEvent: Sendable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var startsAt: Date
    public var endsAt: Date
    public var isAllDay: Bool
    public var location: String
    public var calendarName: String

    public var duration: TimeInterval { endsAt.timeIntervalSince(startsAt) }

    /// "14:00–15:30 Ekip toplantısı" — modele ve arayüze giden tek satır.
    public var summaryLine: String {
        let time = isAllDay
            ? "tüm gün"
            : "\(DateFormat.time(startsAt))–\(DateFormat.time(endsAt))"
        var line = "\(time) \(title)"
        if !location.isEmpty { line += " · \(location)" }
        return line
    }
}

/// Takvim erişimi (MIMARI §11, spec §22).
///
/// Okuma düşük risklidir; **yazma her zaman onay ister** (MIMARI §5 tool
/// kataloğu) — takvim kullanıcının başkalarıyla paylaştığı bir yüzey, ATAK'ın
/// oraya sessizce kayıt düşmesi kabul edilebilir değil.
public actor CalendarService {

    private let store = EKEventStore()

    public init() {}

    // MARK: - İzin

    public nonisolated var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    public nonisolated var hasAccess: Bool {
        authorizationStatus == .fullAccess
    }

    /// Takvim iznini ister. İzin kullanım anında istenir (MIMARI §7).
    @discardableResult
    public func requestAccess() async throws -> Bool {
        // macOS 14 ile `requestAccess(to:)` kullanımdan kalktı; tam erişim
        // API'si hem yazma hem okuma için gerekli olanı veriyor.
        let granted = try await store.requestFullAccessToEvents()
        Log.app.info("Takvim izni: \(granted ? "verildi" : "reddedildi", privacy: .public)")
        return granted
    }

    // MARK: - Okuma

    /// İki tarih arasındaki etkinlikler, başlangıca göre sıralı.
    public func events(from start: Date, to end: Date) throws -> [CalendarEvent] {
        guard hasAccess else {
            throw ATAKError.permissionDenied(.calendar)
        }
        // Boş veya ters aralık EventKit'te sessizce tüm takvimi tarar.
        guard end > start else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(Self.event(from:))
    }

    public func eventsToday() throws -> [CalendarEvent] {
        let bounds = TaskService.todayBounds()
        return try events(from: bounds.start, to: bounds.end)
    }

    /// Verilen gün aralığında ilk boş zaman dilimini arar.
    ///
    /// "Cuma öğleden sonra boş muyum?" sorusunun cevabı; çakışan etkinlikler
    /// birleştirilerek gerçek boşluklar bulunur.
    public func freeSlots(
        from start: Date,
        to end: Date,
        minimumMinutes: Int = 30
    ) throws -> [(start: Date, end: Date)] {
        let busy = try events(from: start, to: end)
            .filter { !$0.isAllDay }
            .map { (start: $0.startsAt, end: $0.endsAt) }

        var slots: [(start: Date, end: Date)] = []
        var cursor = start

        for block in Self.merged(busy) {
            if block.start > cursor,
               block.start.timeIntervalSince(cursor) >= Double(minimumMinutes) * 60 {
                slots.append((cursor, block.start))
            }
            cursor = max(cursor, block.end)
        }
        if end > cursor, end.timeIntervalSince(cursor) >= Double(minimumMinutes) * 60 {
            slots.append((cursor, end))
        }
        return slots
    }

    // MARK: - Yazma

    /// Etkinlik oluşturur ve kimliğini döndürür.
    ///
    /// Çağıran onayı **önceden** almış olmalıdır; bu katman onay sormaz,
    /// yalnız yazar. Onay kararı araç katmanında verilir ki denetim kaydı
    /// (`assistant_action`) ile aynı yerde dursun.
    public func createEvent(
        title: String,
        startsAt: Date,
        endsAt: Date,
        notes: String = ""
    ) throws -> CalendarEvent {
        guard hasAccess else {
            throw ATAKError.permissionDenied(.calendar)
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ATAKError.validation("Etkinlik başlığı boş olamaz.")
        }
        guard endsAt > startsAt else {
            throw ATAKError.validation("Etkinliğin bitişi başlangıcından sonra olmalı.")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw ATAKError.validation("Yazılabilir bir takvim bulunamadı. Takvim uygulamasında en az bir yerel takvim olmalı.")
        }

        let event = EKEvent(eventStore: store)
        event.title = trimmed
        event.startDate = startsAt
        event.endDate = endsAt
        event.notes = notes.isEmpty ? nil : notes
        event.calendar = calendar

        try store.save(event, span: .thisEvent, commit: true)
        return Self.event(from: event)
    }

    /// Geri alma için: ATAK'ın oluşturduğu etkinliği siler.
    public func deleteEvent(identifier: String) throws {
        guard hasAccess else {
            throw ATAKError.permissionDenied(.calendar)
        }
        guard let event = store.event(withIdentifier: identifier) else {
            throw ATAKError.notFound(entity: "Etkinlik", id: identifier)
        }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    // MARK: - Yardımcılar

    /// Çakışan/bitişik meşgul bloklarını birleştirir.
    static func merged(_ blocks: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        let sorted = blocks.sorted { $0.start < $1.start }
        var result: [(start: Date, end: Date)] = []

        for block in sorted {
            if let last = result.last, block.start <= last.end {
                result[result.count - 1].end = max(last.end, block.end)
            } else {
                result.append(block)
            }
        }
        return result
    }

    private static func event(from event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "(başlıksız)",
            startsAt: event.startDate ?? Date(),
            endsAt: event.endDate ?? event.startDate ?? Date(),
            isAllDay: event.isAllDay,
            location: event.location ?? "",
            calendarName: event.calendar?.title ?? ""
        )
    }
}
