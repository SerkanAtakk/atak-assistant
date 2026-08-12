import Foundation

/// Sıralı, ileri yönlü şema migrasyonu.
///
/// Sürüm `PRAGMA user_version` içinde tutulur. Her migrasyon tek bir işlemde
/// çalışır; hata olursa geri alınır ve uygulama bozuk şemayla açılmaz.
enum Migrator {

    struct Migration {
        let version: Int
        let name: String
        let sql: String
    }

    /// - Parameter upTo: Yalnızca bu sürüme kadar taşır. Testlerin eski bir
    ///   veritabanı üretip yükseltme yolunu sınayabilmesi için var; üretimde
    ///   varsayılan (`.max`) kullanılır.
    static func run(on connection: SQLiteConnection, upTo: Int = .max) throws {
        let currentRows = try connection.query("PRAGMA user_version;")
        let current = currentRows.first?.intValue("user_version") ?? 0
        let pending = all
            .filter { $0.version > current && $0.version <= upTo }
            .sorted { $0.version < $1.version }

        guard !pending.isEmpty else {
            Log.database.debug("Şema güncel (v\(current))")
            return
        }

        for migration in pending {
            Log.database.info("Migrasyon uygulanıyor: v\(migration.version) — \(migration.name)")
            do {
                try connection.transaction {
                    try connection.execute(migration.sql)
                    // user_version PRAGMA'sı parametre kabul etmez.
                    try connection.execute("PRAGMA user_version = \(migration.version);")
                }
            } catch {
                throw ATAKError.migration("v\(migration.version) (\(migration.name)): \(error.localizedDescription)")
            }
        }

        Log.database.info("Şema v\(pending.last?.version ?? current) sürümüne taşındı")
    }

    // MARK: - Migrasyonlar

    static let all: [Migration] = [v1Core, v2Chat]

    /// v2 — sohbet mesajlarına araç kullanımı alanları.
    ///
    /// v1 yayınlandıktan (ve gerçek bir veritabanı oluştuktan) sonra eklendiği
    /// için v1 düzenlenmedi; ayrı migrasyon yazıldı.
    private static let v2Chat = Migration(version: 2, name: "chat_tools", sql: """
    ALTER TABLE message ADD COLUMN tool_calls_json TEXT;
    ALTER TABLE message ADD COLUMN tool_call_id    TEXT;
    ALTER TABLE message ADD COLUMN tool_name       TEXT;
    ALTER TABLE message ADD COLUMN is_error        INTEGER NOT NULL DEFAULT 0;
    """)

    /// v1 — MVP çekirdeği (MIMARI §10).
    ///
    /// Tarihler Unix epoch (REAL) olarak saklanır: karşılaştırma ve sıralama
    /// ucuz, `datetime(x,'unixepoch')` ile okunabilir.
    /// UUID'ler TEXT.
    private static let v1Core = Migration(version: 1, name: "core", sql: """
    -- ============ Kimlik & tercih ============
    CREATE TABLE user_profile (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL DEFAULT '',
        occupation  TEXT,
        education   TEXT,
        locale      TEXT NOT NULL DEFAULT 'tr_TR',
        created_at  REAL NOT NULL
    );

    CREATE TABLE user_preference (
        key         TEXT PRIMARY KEY,
        value_json  TEXT NOT NULL,
        updated_at  REAL NOT NULL
    );

    -- ============ Projeler & görevler ============
    CREATE TABLE project (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        status      TEXT NOT NULL DEFAULT 'active',
        color       TEXT NOT NULL DEFAULT 'blue',
        deadline    REAL,
        created_at  REAL NOT NULL,
        archived    INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX idx_project_status ON project(status, archived);

    CREATE TABLE goal (
        id          TEXT PRIMARY KEY,
        project_id  TEXT REFERENCES project(id) ON DELETE CASCADE,
        title       TEXT NOT NULL,
        target_date REAL,
        progress    REAL NOT NULL DEFAULT 0,
        status      TEXT NOT NULL DEFAULT 'active',
        created_at  REAL NOT NULL
    );
    CREATE INDEX idx_goal_project ON goal(project_id);

    CREATE TABLE task (
        id                TEXT PRIMARY KEY,
        project_id        TEXT REFERENCES project(id) ON DELETE SET NULL,
        parent_task_id    TEXT REFERENCES task(id) ON DELETE CASCADE,
        title             TEXT NOT NULL,
        notes             TEXT NOT NULL DEFAULT '',
        status            TEXT NOT NULL DEFAULT 'todo',
        priority          INTEGER NOT NULL DEFAULT 1,
        start_at          REAL,
        due_at            REAL,
        estimated_minutes INTEGER,
        actual_minutes    INTEGER,
        completed_at      REAL,
        created_at        REAL NOT NULL,
        updated_at        REAL NOT NULL,
        sort_order        REAL NOT NULL DEFAULT 0
    );
    CREATE INDEX idx_task_status  ON task(status);
    CREATE INDEX idx_task_due     ON task(due_at);
    CREATE INDEX idx_task_project ON task(project_id);
    CREATE INDEX idx_task_parent  ON task(parent_task_id);

    CREATE TABLE task_tag (
        task_id TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
        tag     TEXT NOT NULL,
        PRIMARY KEY (task_id, tag)
    );
    CREATE INDEX idx_task_tag_tag ON task_tag(tag);

    -- ============ Notlar (FTS5) ============
    -- search_text: TurkishText.fold() ile sadeleştirilmiş başlık+gövde.
    -- FTS5'in remove_diacritics'i Türkçe 'ı' harfini çeviremediği için
    -- normalleştirme Swift tarafında yapılır ve burada saklanır.
    CREATE TABLE note (
        id          TEXT PRIMARY KEY,
        title       TEXT NOT NULL DEFAULT '',
        body        TEXT NOT NULL DEFAULT '',
        search_text TEXT NOT NULL DEFAULT '',
        project_id  TEXT REFERENCES project(id) ON DELETE SET NULL,
        folder      TEXT NOT NULL DEFAULT '',
        created_at  REAL NOT NULL,
        updated_at  REAL NOT NULL
    );
    CREATE INDEX idx_note_project ON note(project_id);
    CREATE INDEX idx_note_updated ON note(updated_at DESC);

    CREATE TABLE note_tag (
        note_id TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
        tag     TEXT NOT NULL,
        PRIMARY KEY (note_id, tag)
    );

    CREATE VIRTUAL TABLE note_fts USING fts5(
        note_id UNINDEXED,
        search_text,
        tokenize = 'unicode61 remove_diacritics 2',
        prefix = '2 3'
    );

    CREATE TRIGGER note_fts_insert AFTER INSERT ON note BEGIN
        INSERT INTO note_fts(note_id, search_text) VALUES (new.id, new.search_text);
    END;
    CREATE TRIGGER note_fts_delete AFTER DELETE ON note BEGIN
        DELETE FROM note_fts WHERE note_id = old.id;
    END;
    CREATE TRIGGER note_fts_update AFTER UPDATE OF search_text ON note BEGIN
        UPDATE note_fts SET search_text = new.search_text WHERE note_id = new.id;
    END;

    -- ============ Sohbet ============
    CREATE TABLE conversation (
        id              TEXT PRIMARY KEY,
        title           TEXT NOT NULL DEFAULT '',
        mode            TEXT NOT NULL DEFAULT 'general',
        started_at      REAL NOT NULL,
        last_message_at REAL,
        is_private      INTEGER NOT NULL DEFAULT 0,
        archived        INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX idx_conversation_recent ON conversation(last_message_at DESC);

    CREATE TABLE message (
        id              TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
        role            TEXT NOT NULL,
        content         TEXT NOT NULL DEFAULT '',
        created_at      REAL NOT NULL,
        model           TEXT,
        token_in        INTEGER,
        token_out       INTEGER
    );
    CREATE INDEX idx_message_conversation ON message(conversation_id, created_at);

    -- ============ Hafıza (FTS5) ============
    CREATE TABLE memory_item (
        id            TEXT PRIMARY KEY,
        kind          TEXT NOT NULL,
        key           TEXT NOT NULL,
        value         TEXT NOT NULL,
        search_text   TEXT NOT NULL DEFAULT '',
        confidence    REAL NOT NULL DEFAULT 1.0,
        source        TEXT NOT NULL,
        pinned        INTEGER NOT NULL DEFAULT 0,
        created_at    REAL NOT NULL,
        last_used_at  REAL,
        use_count     INTEGER NOT NULL DEFAULT 0,
        superseded_by TEXT REFERENCES memory_item(id) ON DELETE SET NULL
    );
    CREATE INDEX idx_memory_key    ON memory_item(key);
    CREATE INDEX idx_memory_active ON memory_item(superseded_by, pinned);

    CREATE VIRTUAL TABLE memory_fts USING fts5(
        memory_id UNINDEXED,
        search_text,
        tokenize = 'unicode61 remove_diacritics 2',
        prefix = '2 3'
    );

    CREATE TRIGGER memory_fts_insert AFTER INSERT ON memory_item BEGIN
        INSERT INTO memory_fts(memory_id, search_text) VALUES (new.id, new.search_text);
    END;
    CREATE TRIGGER memory_fts_delete AFTER DELETE ON memory_item BEGIN
        DELETE FROM memory_fts WHERE memory_id = old.id;
    END;
    CREATE TRIGGER memory_fts_update AFTER UPDATE OF search_text ON memory_item BEGIN
        UPDATE memory_fts SET search_text = new.search_text WHERE memory_id = new.id;
    END;

    -- ============ Odak & zaman ============
    CREATE TABLE timer_session (
        id             TEXT PRIMARY KEY,
        kind           TEXT NOT NULL,
        started_at     REAL NOT NULL,
        ended_at       REAL,
        planned_min    INTEGER NOT NULL,
        actual_min     INTEGER,
        task_id        TEXT REFERENCES task(id) ON DELETE SET NULL,
        interruptions  INTEGER NOT NULL DEFAULT 0,
        note           TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX idx_timer_started ON timer_session(started_at DESC);

    -- ============ Agent denetim izi & güvenlik ============
    CREATE TABLE assistant_action (
        id                 TEXT PRIMARY KEY,
        conversation_id    TEXT REFERENCES conversation(id) ON DELETE SET NULL,
        tool_id            TEXT NOT NULL,
        input_json         TEXT NOT NULL DEFAULT '{}',
        output_json        TEXT,
        risk_level         TEXT NOT NULL,
        required_consent   INTEGER NOT NULL DEFAULT 0,
        consent_granted_at REAL,
        status             TEXT NOT NULL,
        verified           INTEGER NOT NULL DEFAULT 0,
        error              TEXT,
        started_at         REAL NOT NULL,
        ended_at           REAL
    );
    CREATE INDEX idx_action_started ON assistant_action(started_at DESC);

    CREATE TABLE permission_record (
        id         TEXT PRIMARY KEY,
        permission TEXT NOT NULL,
        scope      TEXT NOT NULL DEFAULT '',
        granted_at REAL NOT NULL,
        expires_at REAL,
        revoked_at REAL
    );
    CREATE INDEX idx_permission ON permission_record(permission);

    CREATE TABLE automation (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        trigger_json TEXT NOT NULL,
        action_json  TEXT NOT NULL,
        is_enabled   INTEGER NOT NULL DEFAULT 1,
        last_run_at  REAL,
        next_run_at  REAL,
        created_at   REAL NOT NULL
    );
    """)
}
