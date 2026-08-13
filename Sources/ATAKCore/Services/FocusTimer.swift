import Foundation
import Combine
import UserNotifications

/// Tamamlanmış bir odak seansı (`timer_session`).
public struct TimerSession: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case focus
        case shortBreak
        case longBreak

        public var displayName: String {
            switch self {
            case .focus:      return "Odak"
            case .shortBreak: return "Kısa mola"
            case .longBreak:  return "Uzun mola"
            }
        }
    }

    public let id: UUID
    public var kind: Kind
    public var startedAt: Date
    public var endedAt: Date?
    public var plannedMinutes: Int
    public var actualMinutes: Int?
    public var taskID: UUID?
    public var note: String

    public init(
        id: UUID = UUID(),
        kind: Kind = .focus,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        plannedMinutes: Int,
        actualMinutes: Int? = nil,
        taskID: UUID? = nil,
        note: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedMinutes = plannedMinutes
        self.actualMinutes = actualMinutes
        self.taskID = taskID
        self.note = note
    }

    /// Planlanan sürenin tamamlanıp tamamlanmadığı.
    public var completed: Bool {
        (actualMinutes ?? 0) >= plannedMinutes
    }
}

/// Odak seanslarının kalıcılığı. Saf veri katmanı — test edilebilir.
public struct TimerSessionService: Sendable {

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func record(_ session: TimerSession) async throws {
        try await database.run(
            """
            INSERT INTO timer_session
                (id, kind, started_at, ended_at, planned_min, actual_min,
                 task_id, interruptions, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?);
            """,
            [
                .uuid(session.id), .text(session.kind.rawValue),
                .date(session.startedAt), .dateOrNull(session.endedAt),
                .int(session.plannedMinutes), .intOrNull(session.actualMinutes),
                .uuidOrNull(session.taskID), .text(session.note),
            ]
        )
    }

    public func recent(limit: Int = 20) async throws -> [TimerSession] {
        let rows = try await database.query(
            "SELECT * FROM timer_session ORDER BY started_at DESC LIMIT ?;",
            [.int(limit)]
        )
        return rows.compactMap(Self.session(from:))
    }

    /// Bugün odakta geçirilen toplam dakika — panoda gösterilir.
    public func focusedMinutesToday() async throws -> Int {
        let bounds = TaskService.todayBounds()
        let rows = try await database.query(
            """
            SELECT SUM(actual_min) AS total FROM timer_session
            WHERE kind = 'focus' AND started_at >= ? AND started_at < ?;
            """,
            [.date(bounds.start), .date(bounds.end)]
        )
        return rows.first?.intValue("total") ?? 0
    }

    static func session(from row: Row) -> TimerSession? {
        guard let id = row.uuid("id"), let startedAt = row.date("started_at") else { return nil }
        return TimerSession(
            id: id,
            kind: TimerSession.Kind(rawValue: row.string("kind") ?? "") ?? .focus,
            startedAt: startedAt,
            endedAt: row.date("ended_at"),
            plannedMinutes: row.intValue("planned_min"),
            actualMinutes: row.int("actual_min").map(Int.init),
            taskID: row.uuid("task_id"),
            note: row.string("note") ?? ""
        )
    }
}

/// Çalışan odak zamanlayıcısı (spec §24).
///
/// Sayaç arayüz katmanında yaşar; yalnız biten seans veritabanına yazılır.
/// Her saniyeyi diske yazmak, tek bir sayacı veri tabanı trafiğine çevirirdi.
@MainActor
public final class FocusTimer: ObservableObject {

    @Published public private(set) var session: TimerSession?
    @Published public private(set) var remaining: TimeInterval = 0
    @Published public private(set) var isRunning = false

    private var ticker: Timer?
    private var service: TimerSessionService?
    private var hasRequestedNotifications = false

    public init() {}

    public func configure(_ service: TimerSessionService) {
        self.service = service
    }

    public var progress: Double {
        guard let session, session.plannedMinutes > 0 else { return 0 }
        let total = Double(session.plannedMinutes) * 60
        return min(1, max(0, (total - remaining) / total))
    }

    /// "24:59"
    public var remainingText: String {
        let total = max(0, Int(remaining.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    public func start(minutes: Int, kind: TimerSession.Kind = .focus, taskID: UUID? = nil, note: String = "") {
        stop(persist: true)

        // Bildirim izni ilk sayaçta isteniyor (MIMARI §7: izin kullanım
        // anında). Açılışta sormak, kullanıcının neden sorulduğunu
        // anlamadığı bir kutu demek olurdu.
        if !hasRequestedNotifications {
            hasRequestedNotifications = true
            Task { _ = await Notifier.requestAuthorization() }
        }

        let clamped = min(max(minutes, 1), 180)
        let new = TimerSession(kind: kind, plannedMinutes: clamped, taskID: taskID, note: note)
        session = new
        remaining = Double(clamped) * 60
        isRunning = true

        // `Timer` ana çalışma döngüsüne bağlı; ekran kaydırılırken de saymaya
        // devam etmesi için `.common` moduna eklenmeli.
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker

        Log.app.info("Odak başladı: \(clamped) dk")
    }

    /// Kullanıcı erken bitirirse geçen süre yine de kaydedilir — yarım kalan
    /// bir seans da veridir.
    public func stop(persist: Bool = true) {
        ticker?.invalidate()
        ticker = nil
        isRunning = false

        guard var finished = session else { return }
        session = nil

        guard persist else { return }
        let elapsed = Date().timeIntervalSince(finished.startedAt)
        finished.endedAt = Date()
        finished.actualMinutes = max(0, Int((elapsed / 60).rounded()))

        let record = finished
        Task { [service] in
            try? await service?.record(record)
        }
    }

    private func tick() {
        guard isRunning else { return }
        remaining -= 1

        guard remaining <= 0 else { return }
        remaining = 0
        let kind = session?.kind ?? .focus
        stop(persist: true)
        Notifier.send(
            title: kind == .focus ? "Odak süresi doldu" : "Mola bitti",
            body: kind == .focus ? "Ara vermek için iyi bir an." : "Kaldığın yerden devam."
        )
    }
}

/// `FocusTimer`'ı araç katmanına bağlayan köprü.
///
/// Araç kutusu arka planda çalışan bir `struct`; zamanlayıcı ise `@MainActor`.
/// Köprü, ana aktöre geçişi tek yerde saklıyor.
public struct FocusTimerProxy: FocusTimerControlling {
    private let timer: FocusTimer

    public init(_ timer: FocusTimer) {
        self.timer = timer
    }

    public func startTimer(minutes: Int, note: String) async {
        await MainActor.run {
            timer.start(minutes: minutes, note: note)
        }
    }
}

/// Yerel bildirim gönderir.
///
/// `UNUserNotificationCenter` yalnız gerçek bir uygulama paketi içinde
/// çalışır; `swift test` ve `make smoke` paketsiz çalıştığı için burada
/// sessizce devre dışı kalır. Bu kontrol olmadan testler çökerdi.
enum Notifier {

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.app.error("Bildirim izni alınamadı: \(error.localizedDescription)")
            return false
        }
    }

    static func send(title: String, body: String) {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil          // hemen göster
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.error("Bildirim gönderilemedi: \(error.localizedDescription)")
            }
        }
    }
}
