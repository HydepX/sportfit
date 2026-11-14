import Foundation
import SQLite3
import CryptoKit

/// Append-only results in SQLite. No connection survives an operation, so a
/// journaled restore can safely replace the complete database file.
struct WorkoutDatabase {
    static let filename = "workout_history.sqlite"
    let directory: URL
    private var url: URL { directory.appendingPathComponent(Self.filename) }
    private static func encoded(_ result: WorkoutResult) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(result)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ db: OpaquePointer?) -> Error {
        DataValidation.Failure(message: "База тренировок: " + String(cString: sqlite3_errmsg(db)))
    }
    private func exec(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }
    private func statement(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure(db) }
        return statement
    }
    private func text(_ value: String, at index: Int32, statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw DataValidation.Failure(message: "Не удалось открыть базу тренировок; исходный файл сохранён")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        let version = try statement("PRAGMA user_version", db: db)
        let versionOK = sqlite3_step(version) == SQLITE_ROW && sqlite3_column_int(version, 0) <= 1
        sqlite3_finalize(version)
        guard versionOK else {
            throw DataValidation.Failure(message: "Неподдерживаемая версия базы; обнови приложение")
        }
        try exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS workouts (id TEXT PRIMARY KEY, finished_at REAL NOT NULL, run_id TEXT, payload BLOB NOT NULL, sha256 TEXT NOT NULL); CREATE INDEX IF NOT EXISTS workouts_finished ON workouts(finished_at); CREATE INDEX IF NOT EXISTS workouts_run ON workouts(run_id); CREATE TRIGGER IF NOT EXISTS immutable_update BEFORE UPDATE ON workouts BEGIN SELECT RAISE(ABORT, 'Completed workouts are immutable'); END; CREATE TRIGGER IF NOT EXISTS immutable_delete BEFORE DELETE ON workouts BEGIN SELECT RAISE(ABORT, 'Completed workouts are immutable'); END; PRAGMA user_version=1;", db: db)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
#endif
        return try operation(db)
    }
    private func insert(_ result: WorkoutResult, db: OpaquePointer) throws {
        let payload = try Self.encoded(result)
        let check = try statement("SELECT payload FROM workouts WHERE id=?", db: db); defer { sqlite3_finalize(check) }
        text(result.id.uuidString, at: 1, statement: check)
        let status = sqlite3_step(check)
        if status == SQLITE_ROW {
            let old = Data(bytes: sqlite3_column_blob(check, 0)!, count: Int(sqlite3_column_bytes(check, 0)))
            try DataValidation.require(old == payload, "ID тренировки уже существует с другим содержимым; история не изменена")
            return
        }
        guard status == SQLITE_DONE else { throw failure(db) }
        let insert = try statement("INSERT INTO workouts(id,finished_at,run_id,payload,sha256) VALUES(?,?,?,?,?)", db: db)
        defer { sqlite3_finalize(insert) }
        text(result.id.uuidString, at: 1, statement: insert)
        sqlite3_bind_double(insert, 2, result.finishedAt.timeIntervalSince1970)
        if let id = result.runId { text(id.uuidString, at: 3, statement: insert) } else { sqlite3_bind_null(insert, 3) }
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(insert, 4, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        text(Self.hash(payload), at: 5, statement: insert)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw failure(db) }
    }
    func load() throws -> [WorkoutResult] {
        let legacyURL = directory.appendingPathComponent("workout_history.v1.json")
        let legacy = FileManager.default.fileExists(atPath: legacyURL.path) ? try JSONDecoder().decode([WorkoutResult].self, from: Data(contentsOf: legacyURL)) : []
        try DataValidation.require(Set(legacy.map(\.id)).count == legacy.count, "Повторяющиеся тренировки в старой истории")
        return try withDatabase { db in
            let marker = try statement("SELECT value FROM metadata WHERE key='legacy_imported'", db: db)
            let migrated = sqlite3_step(marker) == SQLITE_ROW; sqlite3_finalize(marker)
            if !migrated {
                try exec("BEGIN IMMEDIATE", db: db)
                do {
                    for result in legacy { try insert(result, db: db) }
                    try exec("INSERT INTO metadata(key,value) VALUES('legacy_imported','1'); COMMIT", db: db)
                } catch { try? exec("ROLLBACK", db: db); throw error }
            }
            let query = try statement("SELECT id,payload,sha256 FROM workouts ORDER BY finished_at,id", db: db); defer { sqlite3_finalize(query) }
            var results: [WorkoutResult] = []
            while true {
                let status = sqlite3_step(query)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 1),
                      let id = sqlite3_column_text(query, 0), let checksum = sqlite3_column_text(query, 2) else { throw failure(db) }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 1)))
                try DataValidation.require(Self.hash(data) == String(cString: checksum), "Повреждена запись базы тренировок; восстанови копию")
                let result = try JSONDecoder().decode(WorkoutResult.self, from: data)
                try DataValidation.require(result.id.uuidString == String(cString: id), "Повреждён ID тренировки")
                results.append(result)
            }
            return results
        }
    }
    func append(_ result: WorkoutResult) throws { try withDatabase { try insert(result, db: $0) } }
    static func image(_ results: [WorkoutResult]) throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sportfit-restore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let database = WorkoutDatabase(directory: temp)
        try database.withDatabase { db in
            try database.exec("BEGIN IMMEDIATE", db: db)
            do {
                for result in results { try database.insert(result, db: db) }
                try database.exec("INSERT INTO metadata(key,value) VALUES('legacy_imported','1'); COMMIT", db: db)
            } catch { try? database.exec("ROLLBACK", db: db); throw error }
        }
        return try Data(contentsOf: temp.appendingPathComponent(filename))
    }
}
