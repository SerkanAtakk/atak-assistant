import Foundation

/// Bir aracın hangi işi yaptığını geri almak için gereken en küçük bilgi.
///
/// Denetim kaydının içinde taşınır: "şu türden şu kaydı oluşturdum" demek,
/// geri almayı ayrı bir defter tutmadan mümkün kılıyor.
public struct UndoToken: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case taskCreated
        case taskCompleted
        case noteCreated
        case projectCreated
        case memoryStored
        case calendarEventCreated
    }

    public var kind: Kind
    public var targetID: String
    /// Kullanıcıya gösterilecek ad: "Spor yap".
    public var label: String

    public init(kind: Kind, targetID: String, label: String) {
        self.kind = kind
        self.targetID = targetID
        self.label = label
    }

    /// Geri alma eyleminin kullanıcıya görünen adı.
    public var undoDescription: String {
        switch kind {
        case .taskCreated:          return "\"\(label)\" görevini sil"
        case .taskCompleted:        return "\"\(label)\" görevini geri aç"
        case .noteCreated:          return "\"\(label)\" notunu sil"
        case .projectCreated:       return "\"\(label)\" projesini sil"
        case .memoryStored:         return "\"\(label)\" hatırlamasını unut"
        case .calendarEventCreated: return "\"\(label)\" etkinliğini takvimden sil"
        }
    }
}

public enum ActionStatus: String, Sendable, Codable {
    case succeeded
    case failed
    /// Kullanıcı onay kartında reddetti.
    case denied
    /// Tur iptal edildi (Durdur düğmesi, pencere kapanışı).
    case cancelled
}

/// ATAK'ın yaptığı her işin denetim kaydı (MIMARI §5, §10).
///
/// "Ne yaptı?" sorusunun tek doğru cevabı burasıdır: sohbet metni modelin
/// iddiasıdır, bu tablo ise gerçekte çalışan işlemdir.
public struct AssistantAction: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var conversationID: UUID?
    public var toolID: String
    public var input: String
    public var summary: String
    public var undo: UndoToken?
    public var risk: RiskLevel
    public var requiredConsent: Bool
    public var consentGrantedAt: Date?
    public var status: ActionStatus
    public var verified: Bool
    public var error: String?
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID = UUID(),
        conversationID: UUID?,
        toolID: String,
        input: String,
        summary: String = "",
        undo: UndoToken? = nil,
        risk: RiskLevel,
        requiredConsent: Bool,
        consentGrantedAt: Date? = nil,
        status: ActionStatus,
        verified: Bool = false,
        error: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.toolID = toolID
        self.input = input
        self.summary = summary
        self.undo = undo
        self.risk = risk
        self.requiredConsent = requiredConsent
        self.consentGrantedAt = consentGrantedAt
        self.status = status
        self.verified = verified
        self.error = error
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var isUndoable: Bool {
        status == .succeeded && undo != nil
    }

    public var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

/// `output_json` sütununun içeriği.
///
/// Ham araç çıktısı yerine yapılandırılmış bir özet saklanıyor: çıktı metni
/// uzun ve modele özgü, oysa denetim kaydının okunabilir kalması gerekiyor.
struct ActionOutput: Codable {
    var summary: String
    var undo: UndoToken?
}
