import XCTest
@testable import SportFit

@MainActor final class ProgramRunIntegrationTests: XCTestCase {
    private func setup() throws -> (URL, FitnessStore, ProfileStore, WorkoutEngine) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FitnessStore(directory: directory)
        let profile = ProfileStore(directory: directory)
        let engine = WorkoutEngine(directory: directory)
        profile.startRun(title: "Test level", program: try XCTUnwrap(store.program), catalog: try XCTUnwrap(store.catalog), draft: nil)
        XCTAssertNotNil(profile.activeRun)
        return (directory, store, profile, engine)
    }
    func testRunAndExtraRestPersistWithoutChangingCurrentDay() async throws {
        let (directory, _, profile, _) = try setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        profile.addExtraRest()
        profile.addExtraRest()
        let restored = ProfileStore(directory: directory)
        XCTAssertEqual(restored.activeRun?.id, profile.activeRun?.id)
        XCTAssertEqual(restored.activeRun?.extraRests.count, 1)
        XCTAssertEqual(restored.activeRun?.currentDay, 0)
    }
    func testRunDraftPreservesExactTargetsAcrossRestartAndAllowsPartialRetry() async throws {
        let (directory, store, profile, engine) = try setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try XCTUnwrap(profile.activeRun)
        engine.start(run: run, store: store)
        XCTAssertEqual(engine.draft?.runId, run.id)
        XCTAssertEqual(engine.draft?.runDayIndex, 0)
        XCTAssertEqual(engine.draft?.date, SportDate.key(Date()))
        XCTAssertEqual(engine.draft?.movements.first?.prescription?.targetSeconds, run.program.sessions?.first?.items.first?.targetSeconds)
        let relaunched = WorkoutEngine(directory: directory)
        XCTAssertEqual(relaunched.draft?.runId, run.id)
        relaunched.earlyFinish()
        let result = try XCTUnwrap(relaunched.finish(feeling: nil))
        XCTAssertEqual(result.runId, run.id)
        XCTAssertFalse(result.isComplete)
        relaunched.start(run: run, store: store)
        XCTAssertNotNil(relaunched.draft)
        XCTAssertEqual(relaunched.history.count, 1)
    }
    func testMultipleProgramDaysCanRunOnSameRealDate() async throws {
        let (directory, store, profile, engine) = try setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        engine.start(run: try XCTUnwrap(profile.activeRun), store: store)
        engine.earlyFinish()
        let first = try XCTUnwrap(engine.finish(feeling: nil))
        profile.closeDay(history: engine.history, draft: nil, allowIncomplete: true)
        profile.closeDay(history: engine.history, draft: nil, allowIncomplete: false)
        XCTAssertEqual(profile.activeRun?.currentDay, 2)
        engine.start(run: try XCTUnwrap(profile.activeRun), store: store)
        XCTAssertEqual(engine.draft?.date, first.date)
        XCTAssertEqual(engine.draft?.runDayIndex, 2)
        XCTAssertEqual(engine.draft?.title, profile.activeRun?.workout(on: 2)?.name)
        XCTAssertNotEqual(engine.draft?.title, first.title)
    }
    func testActiveDraftBlocksDayAndLevelClosure() async throws {
        let (directory, store, profile, engine) = try setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        engine.start(run: try XCTUnwrap(profile.activeRun), store: store)
        profile.closeDay(history: [], draft: engine.draft, allowIncomplete: true)
        profile.closeRun(draft: engine.draft, allowIncomplete: true)
        XCTAssertEqual(profile.activeRun?.currentDay, 0)
        XCTAssertNil(profile.activeRun?.closedAt)
        XCTAssertNotNil(engine.draft)
    }
    func testLegacyDraftBlocksNewRunAndIsNeverRewritten() async throws {
        let (directory, store, profile, engine) = try setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        profile.closeRun(draft: nil, allowIncomplete: true)
        let date = try XCTUnwrap(SportDate.from("2026-11-09"))
        engine.start(day: try XCTUnwrap(store.workout(on: date)), date: date, store: store)
        let data = try Data(contentsOf: directory.appendingPathComponent("active_workout.v1.json"))
        profile.startRun(title: "New", program: try XCTUnwrap(store.program), catalog: try XCTUnwrap(store.catalog), draft: engine.draft)
        XCTAssertNil(profile.activeRun)
        XCTAssertEqual(data, try Data(contentsOf: directory.appendingPathComponent("active_workout.v1.json")))
        XCTAssertNil(engine.draft?.runId)
    }
    func testBackupV3RestoresRunSnapshotProgressAndDraft() async throws {
        let (directory, store, profile, engine) = try setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        profile.closeDay(history: [], draft: nil, allowIncomplete: true)
        profile.closeDay(history: [], draft: nil, allowIncomplete: false)
        engine.start(run: try XCTUnwrap(profile.activeRun), store: store)
        let measurements = MeasurementsStore(directory: directory)
        let backup = SportFitBackup(engine: engine, measurements: measurements, store: store, profile: profile)
        XCTAssertEqual(backup.format, "sportfit-backup-v3")
        let decoded = try BackupEnvelope.decode(BackupEnvelope.encode(backup))
        engine.discard()
        profile.closeRun(draft: nil, allowIncomplete: true)
        try BackupRestore.restore(decoded, engine: engine, measurements: measurements, store: store, profile: profile)
        XCTAssertEqual(profile.activeRun?.currentDay, 2)
        XCTAssertEqual(engine.draft?.runDayIndex, 2)
        XCTAssertEqual(engine.draft?.runId, profile.activeRun?.id)
        XCTAssertEqual(profile.activeRun?.program.sessions?.flatMap(\.items).count, 984)
    }
    func testOlderBackupClearsNewRunStateWithoutLosingLegacyCompatibility() async throws {
        let (directory, store, profile, engine) = try setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        let measurements = MeasurementsStore(directory: directory)
        let backup = SportFitBackup(engine: engine, measurements: measurements, store: store, profile: profile)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
        json["format"] = "sportfit-backup-v2"
        json.removeValue(forKey: "runs")
        let old = try JSONDecoder().decode(SportFitBackup.self, from: JSONSerialization.data(withJSONObject: json))
        try BackupRestore.restore(old, engine: engine, measurements: measurements, store: store, profile: profile)
        XCTAssertTrue(profile.runs.isEmpty)
        XCTAssertNotNil(store.program)
    }
    func testCorruptRunFileIsNotOverwritten() async throws {
        let (directory, store, _, _) = try setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("program_runs.v1.json")
        let broken = Data("broken".utf8)
        try broken.write(to: file)
        let profile = ProfileStore(directory: directory)
        XCTAssertFalse(profile.canExport)
        profile.startRun(title: "New", program: try XCTUnwrap(store.program), catalog: try XCTUnwrap(store.catalog), draft: nil)
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
    func testClosedLevelCannotStartWorkoutAndNewLevelHasIndependentIdentity() async throws {
        let (directory, store, profile, engine) = try setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        profile.closeRun(draft: nil, allowIncomplete: true)
        let closed = try XCTUnwrap(profile.runs.first)
        engine.start(run: closed, store: store)
        XCTAssertNil(engine.draft)
        profile.startRun(title: "Next", program: closed.program, catalog: try XCTUnwrap(store.catalog), draft: nil)
        XCTAssertNotEqual(closed.id, profile.activeRun?.id)
        XCTAssertEqual(profile.activeRun?.currentDay, 0)
        XCTAssertEqual(profile.runs.count, 2)
    }
    func testBackupRejectsMissingRunsAndOrphanedDraftReference() async throws {
        let (directory, store, profile, engine) = try setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        engine.start(run: try XCTUnwrap(profile.activeRun), store: store)
        let backup = SportFitBackup(engine: engine, measurements: MeasurementsStore(directory: directory), store: store, profile: profile)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
        json.removeValue(forKey: "runs")
        let missing = try JSONDecoder().decode(SportFitBackup.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try BackupRestore.validate(missing, fallback: store.catalog))
        json["runs"] = []
        let orphaned = try JSONDecoder().decode(SportFitBackup.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try BackupRestore.validate(orphaned, fallback: store.catalog))
    }
}
