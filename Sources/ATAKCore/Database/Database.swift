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

    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    // MARK: - Kurulum

    public init(path: URL) throws {
        self.path = path

        // `URL(fileURLWithPath: ":memory:")` çalışma dizinine göre mutlak bir
        // URL üretir. SQLite'ın özel adını geri vererek hem gerçek bellek içi
        // bağlantıyı koru hem de çalışma dizininin izinlerini değiştirme.
        if path.lastPathComponent == ":memory:" {
            self.connection = try SQLiteConnection(path: ":memory:")
            return
        }

        let directory = path.deletingLastPathComponent()
        try Self.prepareSecureDirectory(directory)

        // Klasör önce 0700 yapılır; böylece SQLite dosyayı oluştururken oluşan
        // kısa aralıkta bile başka kullanıcılar dizine giremez.
        let connection = try SQLiteConnection(path: path.path)
        try Self.secureDatabaseFiles(at: path)
        self.connection = connection
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
        try secured {
            try connection.run(sql, parameters)
        }
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        try secured {
            try connection.query(sql, parameters)
        }
    }

    public func queryOne(_ sql: String, _ parameters: [SQLValue] = []) throws -> Row? {
        try secured {
            try connection.query(sql, parameters).first
        }
    }

    /// Birden çok ifadeyi tek işlemde (atomik) çalıştırır.
    /// Herhangi biri hata verirse tamamı geri alınır.
    public func transaction(_ statements: [SQLStatement]) throws {
        try secured {
            try connection.transaction {
                for statement in statements {
                    try connection.run(statement.sql, statement.parameters)
                }
            }
        }
    }

    /// Parametresiz, çok ifadeli SQL (şema kurulumu için).
    public func executeScript(_ sql: String) throws {
        try secured {
            try connection.execute(sql)
        }
    }

    // MARK: - Bakım

    /// Şemayı en güncel sürüme taşır. Uygulama açılışında bir kez çağrılır.
    public func migrate() throws {
        try secured {
            try Migrator.run(on: connection)
        }
    }

    /// Yalnızca belirtilen sürüme kadar taşır — testlerin eski bir veritabanı
    /// üretip yükseltme yolunu sınaması için.
    func migrate(upTo version: Int) throws {
        try secured {
            try Migrator.run(on: connection, upTo: version)
        }
    }

    public func currentSchemaVersion() throws -> Int {
        try secured {
            let rows = try connection.query("PRAGMA user_version;")
            return rows.first?.intValue("user_version") ?? 0
        }
    }

    /// Veritabanının açılıp açılmadığını ve yazılabilir olduğunu doğrular.
    public func healthCheck() throws -> String {
        try secured {
            let rows = try connection.query("PRAGMA integrity_check;")
            return rows.first?.string("integrity_check") ?? "bilinmiyor"
        }
    }

    public func vacuum() throws {
        try secured {
            try connection.execute("VACUUM;")
        }
    }

    // MARK: - Dosya izinleri

    /// SQLite WAL/SHM dosyalarını ilk yazıda oluşturabildiği için her erişimin
    /// sonunda izinleri yeniden doğrular. Klasörün 0700 olması savunmanın ilk
    /// katmanıdır; dosyaların 0600 olması yedekleme/kopyalama sırasında da
    /// verinin yanlışlıkla okunabilir kalmasını engeller.
    private func secured<T>(_ operation: () throws -> T) throws -> T {
        if path.lastPathComponent == ":memory:" {
            return try operation()
        }

        let result: Result<T, Error>
        do {
            result = .success(try operation())
        } catch {
            result = .failure(error)
        }

        // SQL başarısız olsa bile o sırada oluşturulmuş WAL/SHM dosyalarını
        // açık izinlerle bırakma. Güvenlik hatası, işlemin sonucundan önce gelir.
        try Self.secureDatabaseFiles(at: path)
        return try result.get()
    }

    private static func prepareSecureDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
        } catch {
            throw ATAKError.database(
                "Veritabanı klasörü oluşturulamadı (\(directory.path)): \(error.localizedDescription)"
            )
        }

        try setPermissions(directoryPermissions, at: directory, allowMissing: false)
    }

    private static func secureDatabaseFiles(at databaseURL: URL) throws {
        try setPermissions(filePermissions, at: databaseURL, allowMissing: false)
        try setPermissions(
            filePermissions,
            at: URL(fileURLWithPath: databaseURL.path + "-wal"),
            allowMissing: true
        )
        try setPermissions(
            filePermissions,
            at: URL(fileURLWithPath: databaseURL.path + "-shm"),
            allowMissing: true
        )
    }

    private static func setPermissions(
        _ expected: Int,
        at url: URL,
        allowMissing: Bool
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            if allowMissing { return }
            throw ATAKError.database("Güvenli izin verilecek dosya bulunamadı: \(url.path)")
        }

        do {
            try fileManager.setAttributes(
                [.posixPermissions: expected],
                ofItemAtPath: url.path
            )
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let actual = (attributes[.posixPermissions] as? NSNumber)?.intValue
            guard actual.map({ $0 & 0o777 }) == expected else {
                throw ATAKError.database(
                    "Güvenli dosya izinleri doğrulanamadı (\(url.path))."
                )
            }
        } catch let error as ATAKError {
            throw error
        } catch {
            throw ATAKError.database(
                "Güvenli dosya izinleri ayarlanamadı (\(url.path)): \(error.localizedDescription)"
            )
        }
    }
}
