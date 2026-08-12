import Foundation
import SQLite3

// sqlite3_bind_text/blob'a "bu tamponu kendin kopyala" demek için gereken sabit.
// C makrosu Swift'e gelmediğinden elle tanımlanır.
nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)

/// SQLite'a bağlanabilen tek bir değer.
public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// Sorgudan dönen tek satır.
///
/// Değerler okunur okunmaz Swift tiplerine kopyalanır; bu sayede `Sendable`
/// olur ve aktörün dışına güvenle çıkabilir (MIMARI §1: satır asla referans
/// tip olarak UI'a sızmaz).
public struct Row: Sendable {
    private let values: [String: SQLValue]

    init(values: [String: SQLValue]) { self.values = values }

    public subscript(_ column: String) -> SQLValue {
        values[column] ?? .null
    }

    public func int(_ column: String) -> Int64? {
        if case .integer(let v) = self[column] { return v }
        return nil
    }

    public func intValue(_ column: String, default fallback: Int = 0) -> Int {
        int(column).map(Int.init) ?? fallback
    }

    public func double(_ column: String) -> Double? {
        switch self[column] {
        case .real(let v):    return v
        case .integer(let v): return Double(v)
        default:              return nil
        }
    }

    public func string(_ column: String) -> String? {
        if case .text(let v) = self[column] { return v }
        return nil
    }

    public func bool(_ column: String) -> Bool? {
        int(column).map { $0 != 0 }
    }

    public func date(_ column: String) -> Date? {
        double(column).map { Date(timeIntervalSince1970: $0) }
    }

    public func uuid(_ column: String) -> UUID? {
        string(column).flatMap(UUID.init(uuidString:))
    }

    public func data(_ column: String) -> Data? {
        if case .blob(let v) = self[column] { return v }
        return nil
    }
}

/// Ham SQLite bağlantısı. `OpaquePointer` taşıdığı için `Sendable` DEĞİLDİR —
/// yalnızca `Database` aktörünün içinde yaşar.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    let path: String

    init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { Self.message(from: $0) } ?? "bağlantı açılamadı"
            sqlite3_close_v2(db)
            throw ATAKError.database("Veritabanı açılamadı (\(path)): \(message)")
        }
        self.handle = db

        // Dayanıklılık + eşzamanlı okuma için WAL; yabancı anahtar zorunlu.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA busy_timeout = 5000;")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: - Çalıştırma

    /// Sonuç döndürmeyen, birden çok ifade içerebilen SQL çalıştırır.
    func execute(_ sql: String) throws {
        guard let handle else { throw ATAKError.database("bağlantı kapalı") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if status != SQLITE_OK {
            let detail = errorPointer.map { String(cString: $0) } ?? "bilinmeyen hata"
            sqlite3_free(errorPointer)
            throw ATAKError.database(detail)
        }
    }

    /// Parametreli, sonuç döndürmeyen ifade. Etkilenen satır sayısını verir.
    @discardableResult
    func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        guard let handle else { throw ATAKError.database("bağlantı kapalı") }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw ATAKError.database(Self.message(from: handle))
        }
        return Int(sqlite3_changes(handle))
    }

    /// Parametreli sorgu; tüm satırları okuyup döndürür.
    func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        guard let handle else { throw ATAKError.database("bağlantı kapalı") }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let columnCount = sqlite3_column_count(statement)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            names.append(sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "\(index)")
        }

        var rows: [Row] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw ATAKError.database(Self.message(from: handle))
            }

            var values: [String: SQLValue] = [:]
            values.reserveCapacity(Int(columnCount))
            for index in 0..<columnCount {
                values[names[Int(index)]] = Self.value(from: statement, at: index)
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    func lastInsertRowID() -> Int64 {
        handle.map { sqlite3_last_insert_rowid($0) } ?? 0
    }

    // MARK: - İşlem (transaction)

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Yardımcılar

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer? {
        guard let handle else { throw ATAKError.database("bağlantı kapalı") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let detail = Self.message(from: handle)
            sqlite3_finalize(statement)
            throw ATAKError.database("\(detail)\nSQL: \(sql)")
        }
        for (offset, value) in parameters.enumerated() {
            try bind(value, to: statement, at: Int32(offset + 1))
        }
        return statement
    }

    private func bind(_ value: SQLValue, to statement: OpaquePointer?, at index: Int32) throws {
        let status: Int32
        switch value {
        case .null:
            status = sqlite3_bind_null(statement, index)
        case .integer(let v):
            status = sqlite3_bind_int64(statement, index, v)
        case .real(let v):
            status = sqlite3_bind_double(statement, index, v)
        case .text(let v):
            status = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
        case .blob(let v):
            status = v.isEmpty
                ? sqlite3_bind_zeroblob(statement, index, 0)
                : v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
        }
        guard status == SQLITE_OK else {
            throw ATAKError.database("parametre \(index) bağlanamadı")
        }
    }

    private static func value(from statement: OpaquePointer?, at index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: pointer))
        case SQLITE_BLOB:
            guard let pointer = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            let count = Int(sqlite3_column_bytes(statement, index))
            return .blob(Data(bytes: pointer, count: count))
        default:
            return .null
        }
    }

    private static func message(from handle: OpaquePointer) -> String {
        sqlite3_errmsg(handle).map { String(cString: $0) } ?? "bilinmeyen SQLite hatası"
    }
}

// MARK: - Swift tiplerinden SQLValue üretme kolaylıkları

// Optional alan varyantları bilerek AYRI isimler taşır: `text(String)` zaten
// enum case'inin ürettiği bir fabrika olduğundan, `text(String?)` overload'u
// hem çağrı yerinde belirsizlik hem de sonsuz özyineleme riski yaratırdı.
extension SQLValue {
    public static func textOrNull(_ value: String?) -> SQLValue {
        if let value { return .text(value) }
        return .null
    }
    public static func uuid(_ value: UUID) -> SQLValue { .text(value.uuidString) }
    public static func uuidOrNull(_ value: UUID?) -> SQLValue {
        if let value { return .text(value.uuidString) }
        return .null
    }
    public static func date(_ value: Date) -> SQLValue { .real(value.timeIntervalSince1970) }
    public static func dateOrNull(_ value: Date?) -> SQLValue {
        if let value { return .real(value.timeIntervalSince1970) }
        return .null
    }
    public static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
    public static func int(_ value: Int) -> SQLValue { .integer(Int64(value)) }
    public static func intOrNull(_ value: Int?) -> SQLValue {
        if let value { return .integer(Int64(value)) }
        return .null
    }
}
