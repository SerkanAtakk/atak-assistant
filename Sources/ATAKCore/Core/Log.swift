import Foundation
import os

/// Merkezî loglama.
///
/// Güvenlik kuralı (MIMARI §8): API anahtarı, token ve dosya içeriği loglanmaz.
/// Hassas değerler `redacted(_:)` ile maskelenir.
public enum Log {
    private static let subsystem = "com.serkanatak.atak"

    public static let app       = Logger(subsystem: subsystem, category: "app")
    public static let database  = Logger(subsystem: subsystem, category: "database")
    public static let agent     = Logger(subsystem: subsystem, category: "agent")
    public static let ai        = Logger(subsystem: subsystem, category: "ai")
    public static let tools     = Logger(subsystem: subsystem, category: "tools")
    public static let security  = Logger(subsystem: subsystem, category: "security")
    public static let memory    = Logger(subsystem: subsystem, category: "memory")

    /// Sırrı loga güvenli biçimde yazmak için maskeler: `sk-ant-…4f2a` → `sk-a…(38)`
    public static func redacted(_ secret: String) -> String {
        guard secret.count > 6 else { return "…(\(secret.count))" }
        return "\(secret.prefix(4))…(\(secret.count))"
    }
}
