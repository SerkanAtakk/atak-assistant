import Foundation

/// Bir aracın taşıdığı risk (MIMARI §8).
public enum RiskLevel: String, Sendable, Codable, Comparable, CaseIterable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low:    return "Düşük"
        case .medium: return "Orta"
        case .high:   return "Yüksek"
        }
    }

    private var order: Int {
        switch self {
        case .low:    return 0
        case .medium: return 1
        case .high:   return 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.order < rhs.order
    }

    /// Bir seviye yukarı. `high` tavandır.
    func escalated() -> RiskLevel {
        switch self {
        case .low:    return .medium
        case .medium: return .high
        case .high:   return .high
        }
    }
}

/// Bir aracın sabit güvenlik künyesi (MIMARI §5, tool sözleşmesi).
///
/// Aracın kendi kodundan ayrı tutuluyor: bir aracın ne kadar tehlikeli olduğu,
/// ne yaptığından bağımsız olarak tek bir yerden okunabilmeli.
public struct ToolSafety: Sendable, Equatable {
    public var risk: RiskLevel
    public var permission: Permission?
    /// Kullanıcı onayı olmadan hiç çalışmaz.
    public var alwaysRequiresConsent: Bool
    /// Geri alınabilir mi? Geri alınamayan işler risk sınıfını yükseltir.
    public var isReversible: Bool
    /// Modelin çağrısı kullanıcıya nasıl anlatılır.
    public var friendlyName: String

    public init(
        risk: RiskLevel,
        permission: Permission? = nil,
        alwaysRequiresConsent: Bool = false,
        isReversible: Bool = true,
        friendlyName: String
    ) {
        self.risk = risk
        self.permission = permission
        self.alwaysRequiresConsent = alwaysRequiresConsent
        self.isReversible = isReversible
        self.friendlyName = friendlyName
    }
}

/// Çağrı anındaki bağlam. Risk statik değildir, bağlamla yükselir.
public struct RiskContext: Sendable, Equatable {
    /// Kaç kayıt etkileniyor (silme, toplu güncelleme).
    public var affectedCount: Int
    /// Veri dış dünyaya çıkıyor mu (e-posta, web POST)?
    public var leavesDevice: Bool
    /// Aracın girdisi modelin kendi akıl yürütmesinden değil, ATAK'ın okuduğu
    /// bir içerikten (PDF, e-posta, web sayfası) türedi mi?
    ///
    /// Bu, prompt injection'ın tek gerçek savunma noktasıdır: okunan içerik
    /// veridir, talimat değil. Oradan türeyen her iş kullanıcıya sorulur.
    public var derivedFromUntrustedContent: Bool

    public init(
        affectedCount: Int = 1,
        leavesDevice: Bool = false,
        derivedFromUntrustedContent: Bool = false
    ) {
        self.affectedCount = affectedCount
        self.leavesDevice = leavesDevice
        self.derivedFromUntrustedContent = derivedFromUntrustedContent
    }

    public static let plain = RiskContext()
}

/// Bir aracın çalıştırılmadan önceki değerlendirmesi.
public struct RiskAssessment: Sendable, Equatable {
    public var level: RiskLevel
    public var requiresConsent: Bool
    public var isReversible: Bool
    /// Riskin neden yükseldiği — onay kartında kullanıcıya gösterilir.
    public var reasons: [String]
}

/// Risk sınıflandırıcı (MIMARI §8).
///
/// Saf bir fonksiyon: aynı künye ve bağlam her zaman aynı sonucu verir, bu
/// yüzden tamamen test edilebilir.
public enum RiskEngine {

    /// Toplu işlem sayılmaya başlanan eşik.
    public static let bulkThreshold = 5

    public static func assess(_ safety: ToolSafety, context: RiskContext = .plain) -> RiskAssessment {
        var level = safety.risk
        var reasons: [String] = []

        if !safety.isReversible {
            level = level.escalated()
            reasons.append("Geri alınamaz.")
        }
        if context.affectedCount > bulkThreshold {
            level = level.escalated()
            reasons.append("\(context.affectedCount) kaydı birden etkiliyor.")
        }
        if context.leavesDevice {
            level = level.escalated()
            reasons.append("Veri bu Mac'ten dışarı çıkıyor.")
        }
        if context.derivedFromUntrustedContent {
            level = level.escalated()
            reasons.append("İstek, ATAK'ın okuduğu bir içerikten türedi — senin talimatın değil.")
        }

        // Onay iki yoldan gelir: aracın künyesi zaten şart koşuyordur ya da
        // bağlam riski yüksek seviyeye çıkarmıştır.
        let requiresConsent = safety.alwaysRequiresConsent || level == .high

        return RiskAssessment(
            level: level,
            requiresConsent: requiresConsent,
            isReversible: safety.isReversible,
            reasons: reasons
        )
    }
}
