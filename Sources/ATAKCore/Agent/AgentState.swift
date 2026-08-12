import Foundation

/// ATAK'ın kullanıcıya gösterilen çalışma durumu (spec §45, MIMARI §2).
public enum AgentState: Sendable, Equatable {
    case ready
    case listening
    case thinking
    case researching
    case working(tool: String)
    case awaitingConsent
    case offline
    case error(String)

    public var displayName: String {
        switch self {
        case .ready:            return "ATAK Hazır"
        case .listening:        return "ATAK Dinliyor"
        case .thinking:         return "ATAK Düşünüyor"
        case .researching:      return "ATAK Araştırıyor"
        case .working(let tool): return "ATAK Çalışıyor — \(tool)"
        case .awaitingConsent:  return "ATAK Onay Bekliyor"
        case .offline:          return "ATAK Çevrimdışı"
        case .error:            return "ATAK Hata Verdi"
        }
    }

    /// Meşgul durumlarda gösterge nabız atar; boştayken animasyon çalışmaz.
    public var isBusy: Bool {
        switch self {
        case .thinking, .researching, .working, .listening: return true
        case .ready, .offline, .awaitingConsent, .error:    return false
        }
    }
}
