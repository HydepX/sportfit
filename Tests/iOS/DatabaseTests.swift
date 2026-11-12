import XCTest
import SQLite3
@testable import SportFit

@MainActor final class DatabaseTests: XCTestCase {
    private func setup() throws -> (URL, WorkoutEngine, FitnessStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, WorkoutEngine(directory: directory), FitnessStore(directory: directory))
    }
    private func save(_ engine: WorkoutEngine, _ store: FitnessStore) throws -> WorkoutResult {
        engine.start(day: ProgramDay(dayOfWeek: "test", name: "test", exerciseIds: ["press_floor"]), date: Date(), store: store)
        engine.begin(); engine.complete(reps: 4, weight: 0, seconds: nil); engine.earlyFinish()
        return try XCTUnwrap(engine.finish(feeling: nil))
    }
    func testDatabasePersistsAndRejectsConflictingUUIDWithoutChangingResult() async throws {
        let (directory, engine, store) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        let result = try save(engine, store), database = WorkoutDatabase(directory: directory)
        try database.append(result)
        XCTAssertEqual(try database.load().count, 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]); json["title"] = "changed"
        let changed = try JSONDecoder().decode(WorkoutResult.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try database.append(changed))
        XCTAssertEqual(try database.load().first?.title, result.title)
        XCTAssertEqual(WorkoutEngine(directory: directory).history.first?.id, result.id)
    }
    func testLegacyMigrationKeepsOriginalFileAndDoesNotDuplicateOnReload() async throws {
        let (directory, engine, store) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        let result = try save(engine, store)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(WorkoutDatabase.filename))
        let file = directory.appendingPathComponent("workout_history.v1.json"), bytes = try JSONEncoder().encode([result])
        try bytes.write(to: file)
        XCTAssertEqual(try WorkoutDatabase(directory: directory).load().map(\.id), [result.id])
        XCTAssertEqual(try WorkoutDatabase(directory: directory).load().count, 1)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testDatabaseTriggersPreventHistoryMutation() async throws {
        let (directory, engine, store) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try save(engine, store)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(directory.appendingPathComponent(WorkoutDatabase.filename).path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertNotEqual(sqlite3_exec(db, "DELETE FROM workouts", nil, nil, nil), SQLITE_OK)
        XCTAssertNotEqual(sqlite3_exec(db, "UPDATE workouts SET sha256='bad'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try WorkoutDatabase(directory: directory).load().count, 1)
    }
    func testCorruptDatabaseDoesNotFallBackToStaleLegacyOrOverwriteFile() async throws {
        let (directory, _, _) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(WorkoutDatabase.filename), broken = Data("corrupt database".utf8)
        try broken.write(to: file)
        let loaded = WorkoutEngine(directory: directory)
        XCTAssertFalse(loaded.canExport)
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
}
