import Foundation
import Combine

/// Kullanıcıya sorulan tek bir onay isteği (MIMARI §8, onay ekranı).
public struct ConsentRequest: Sendable, Identifiable, Equatable {
    public let id = UUID()
    /// "14 dosyayı sil" — ne yapılacağının tek cümlelik hâli.
    public let title: String
    /// ATAK'ın gerekçesi; modelin kendi cümlesi.
    public let rationale: String
    public let assessment: RiskAssessment
    /// Etkilenecek kayıtlar — kullanıcı "göster" derse listelenir.
    public let affected: [String]

    public init(
        title: String,
        rationale: String,
        assessment: RiskAssessment,
        affected: [String] = []
    ) {
        self.title = title
        self.rationale = rationale
        self.assessment = assessment
        self.affected = affected
    }
}

public enum ConsentDecision: Sendable, Equatable {
    case approved
    case denied
    /// Kullanıcı turu iptal etti ya da uygulama kapanıyor.
    case cancelled

    public var isApproved: Bool { self == .approved }
}

/// Riskli araçları kullanıcı onayına bağlayan kapı (MIMARI §5 yürütme hattı).
///
/// Araç arka planda çalışır, onay ise ana iş parçacığındaki arayüzden gelir.
/// Kapı bu ikisini bir devam noktası (continuation) üzerinden birleştirir:
/// `await request(...)` çağrısı kullanıcı karar verene kadar askıda kalır.
///
/// Askıya alınmış bir devam noktası asla sızdırılmamalı — aksi hâlde tur
/// sonsuza kadar donar. Bu yüzden iptal (`Durdur` düğmesi, pencere kapanması)
/// açıkça ele alınıyor.
@MainActor
public final class ConsentGate: ObservableObject {

    @Published public private(set) var pending: ConsentRequest?

    private var continuation: CheckedContinuation<ConsentDecision, Never>?

    public init() {}

    /// Onay ister ve kullanıcı karar verene kadar bekler.
    public func request(_ request: ConsentRequest) async -> ConsentDecision {
        // Aynı anda ikinci bir istek: araç çağrıları sıralı yürütüldüğü için
        // normalde olmaz. Olursa ilkini iptal etmek yerine ikinciyi reddediyoruz;
        // ekranda görünmeyen bir isteğin onaylanmış sayılması en kötü sonuç.
        guard pending == nil else {
            Log.security.error("Onay kapısı meşgulken ikinci istek geldi — reddedildi")
            return .denied
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Görev bu noktaya gelmeden iptal edilmiş olabilir.
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                self.continuation = continuation
                self.pending = request
                Log.security.info(
                    "Onay istendi: \(request.assessment.level.rawValue, privacy: .public)"
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.cancelled) }
        }
    }

    public func approve() {
        Log.security.info("Onay verildi")
        finish(.approved)
    }

    public func deny() {
        Log.security.info("Onay reddedildi")
        finish(.denied)
    }

    /// Pencere kapanırken veya tur iptal edilirken askıdaki isteği serbest bırakır.
    public func cancelPending() {
        finish(.cancelled)
    }

    private func finish(_ decision: ConsentDecision) {
        guard let continuation else { return }
        self.continuation = nil
        self.pending = nil
        continuation.resume(returning: decision)
    }
}

/// Araç katmanının onay isteyebilmesi için gereken en dar arayüz.
///
/// `ATAKToolbox` bir `struct` ve arka planda çalışıyor; tüm `ConsentGate`
/// sınıfına değil yalnız bu tek yeteneğe ihtiyacı var. Testler burada gerçek
/// arayüz yerine sabit karar veren bir sahte kullanıyor.
public protocol ConsentRequesting: Sendable {
    func requestConsent(_ request: ConsentRequest) async -> ConsentDecision
}

/// `ConsentGate`'i araç katmanına bağlayan köprü.
public struct ConsentGateBridge: ConsentRequesting {
    private let gate: ConsentGate

    public init(_ gate: ConsentGate) {
        self.gate = gate
    }

    public func requestConsent(_ request: ConsentRequest) async -> ConsentDecision {
        await gate.request(request)
    }
}

/// Onay istemeden hep aynı kararı veren kapı — testler ve onay gerektiren
/// aracın hiç bulunmadığı yapılandırmalar için.
public struct FixedConsent: ConsentRequesting {
    private let decision: ConsentDecision

    public init(_ decision: ConsentDecision) {
        self.decision = decision
    }

    public func requestConsent(_ request: ConsentRequest) async -> ConsentDecision {
        decision
    }
}
