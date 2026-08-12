import Foundation

/// Tek bir parametreli SQL ifadesi. `Sendable` olduğu için aktör sınırını geçebilir.
public struct SQLStatement: Sendable {
    public let sql: String
    public let parameters: [SQLValue]

    public init(_ sql: String, _ parameters: [SQLValue] = []) {
        self.sql = sql
        self.parameters = parameters
    }
}

/// ATAK'ın kalıcılık katmanı.
///
/// Aktör olduğu için tüm SQL erişimi seri hâle gelir — SQLite bağlantısı
/// (`OpaquePointer` taşıdığından `Sendable` değildir) hiçbir zaman aktörün
/// dışına çıkmaz. Dışarıya yalnız `Sendable` `Row` değerleri döner.
public actor Database {

    private let connection: SQLiteConnection

    public nonisolated let path: URL

    // MARK: - Kurulum

    public init(path: URL) throws {
        self.path = path
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.connection = try SQLiteConnection(path: path.path)
    }

    /// Bellek içi veritabanı — testler için.
    public static func inMemory() throws -> Database {
        try Database(path: URL(fileURLWithPath: ":memory:"))
    }

    /// Uygulamanın gerçek veritabanı konumu:
    /// `~/Library/Application Support/ATAK/atak.db`
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "ATAK/atak.db")
    }

    // MARK: - Erişim

    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        try connection.run(sql, parameters)
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        try connection.query(sql, parameters)
    }

    public func queryOne(_ sql: String, _ parameters: [SQLValue] = []) throws -> Row? {
        try connection.query(sql, parameters).first
    }

    /// Birden çok ifadeyi tek işlemde (atomik) çalıştırır.
    /// Herhangi biri hata verirse tamamı geri alınır.
    public func transaction(_ statements: [SQLStatement]) throws {
        try connection.transaction {
            for statement in statements {
                try connection.run(statement.sql, statement.parameters)
            }
        }
    }

    /// Parametresiz, çok ifadeli SQL (şema kurulumu için).
    public func executeScript(_ sql: String) throws {
        try connection.execute(sql)
    }

    // MARK: - Bakım

    /// Şemayı en güncel sürüme taşır. Uygulama açılışında bir kez çağrılır.
    public func migrate() throws {
        try Migrator.run(on: connection)
    }

    /// Yalnızca belirtilen sürüme kadar taşır — testlerin eski bir veritabanı
    /// üretip yükseltme yolunu sınaması için.
    func migrate(upTo version: Int) throws {
        try Migrator.run(on: connection, upTo: version)
    }

    public func currentSchemaVersion() throws -> Int {
        let rows = try connection.query("PRAGMA user_version;")
        return rows.first?.intValue("user_version") ?? 0
    }

    /// Veritabanının açılıp açılmadığını ve yazılabilir olduğunu doğrular.
    public func healthCheck() throws -> String {
        let rows = try connection.query("PRAGMA integrity_check;")
        return rows.first?.string("integrity_check") ?? "bilinmiyor"
    }

    public func vacuum() throws {
        try connection.execute("VACUUM;")
    }
}
