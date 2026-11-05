import XCTest
@testable import SportFit

@MainActor final class WorkoutTests: XCTestCase {
    private func makeEngine() throws -> (WorkoutEngine, FitnessStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FitnessStore(directory: directory)
        XCTAssertNotNil(store.catalog)
        XCTAssertNotNil(store.program)
        return (WorkoutEngine(directory: directory), store, directory)
    }
    func testRestPauseResumeAndRelaunch() async throws {
        let (engine, store, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = ProgramDay(dayOfWeek: "Пн", name: "Тест", exerciseIds: ["press_floor"])
        engine.start(day: day, date: Date(), store: store)
        engine.begin()
        engine.complete(reps: 10, weight: 2, seconds: nil)
        XCTAssertEqual(engine.draft?.phase, .rest)
        XCTAssertGreaterThan(engine.restRemaining(), 0)
        engine.pause()
        XCTAssertEqual(engine.draft?.phase, .paused)
        let relaunched = WorkoutEngine(directory: directory)
        XCTAssertEqual(relaunched.draft?.phase, .paused)
        relaunched.resume()
        XCTAssertEqual(relaunched.draft?.phase, .rest)
        XCTAssertGreaterThan(relaunched.restRemaining(), 0)
        XCTAssertEqual(relaunched.draft?.completedSetCount, 1)
    }
    func testEditingAndIdempotentFinish() async throws {
        let (engine, store, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        engine.start(day: ProgramDay(dayOfWeek: "Пн", name: "Тест", exerciseIds: ["press_floor"]), date: Date(), store: store)
        engine.begin()
        engine.complete(reps: 10, weight: 2, seconds: nil)
        let id = try XCTUnwrap(engine.draft?.movements.first?.sets.first?.id)
        engine.editSet(id, reps: 12, weight: 3, seconds: nil)
        XCTAssertEqual(engine.draft?.movements.first?.sets.first?.reps, 12)
        engine.nextExercise()
        let ended = try XCTUnwrap(engine.draft?.endedAt)
        XCTAssertEqual(engine.draft?.activeSeconds(now: ended.addingTimeInterval(100)), engine.draft?.activeSeconds(now: ended))
        XCTAssertNotNil(engine.finish(feeling: nil))
        XCTAssertNil(engine.finish(feeling: nil))
        XCTAssertEqual(WorkoutEngine(directory: directory).history.count, 1)
    }
    func testInvalidAndDeletedSets() async throws {
        let (engine, store, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        engine.start(day: ProgramDay(dayOfWeek: "Пн", name: "Тест", exerciseIds: ["press_floor"]), date: Date(), store: store)
        engine.begin()
        engine.complete(reps: -1, weight: 2, seconds: nil)
        XCTAssertEqual(engine.draft?.completedSetCount, 0)
        engine.complete(reps: 10, weight: 2, seconds: nil)
        let id = try XCTUnwrap(engine.draft?.movements.first?.sets.first?.id)
        engine.deleteSet(id)
        XCTAssertEqual(engine.draft?.completedSetCount, 0)
    }
    func testCorruptHistoryIsNeverOverwritten() async throws {
        let (engine, store, directory) = try makeEngine()
        _ = engine
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workout_history.v1.json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: file)
        let loaded = WorkoutEngine(directory: directory)
        loaded.start(day: ProgramDay(dayOfWeek: "Пн", name: "Тест", exerciseIds: ["press_floor"]), date: Date(), store: store)
        XCTAssertNil(loaded.draft)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testBackupRoundTripAndRejectsBadVersion() async throws {
        let (engine, store, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = SportFitBackup(engine: engine, measurements: MeasurementsStore(directory: directory), store: store, profile: ProfileStore(directory: directory))
        let envelopeData = try BackupEnvelope.encode(backup)
        let envelopeRestored = try BackupEnvelope.decode(envelopeData)
        XCTAssertEqual(envelopeRestored.format, backup.format)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: envelopeData) as? [String: Any])
        envelope["sha256"] = "invalid"
        XCTAssertThrowsError(try BackupEnvelope.decode(JSONSerialization.data(withJSONObject: envelope)))
        let data = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(SportFitBackup.self, from: data)
        try BackupRestore.validate(decoded, fallback: store.catalog)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["format"] = "future-v999"
        let invalid = try JSONDecoder().decode(SportFitBackup.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try BackupRestore.validate(invalid, fallback: store.catalog))
    }
    func testCalendarBoundaries() async throws {
        let (_, store, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(store.weekNumber(for: try XCTUnwrap(SportDate.from("2026-11-08"))))
        XCTAssertEqual(store.weekNumber(for: try XCTUnwrap(SportDate.from("2026-11-09"))), 1)
        XCTAssertEqual(store.weekNumber(for: try XCTUnwrap(SportDate.from("2027-01-31"))), 12)
        XCTAssertNil(store.workout(on: try XCTUnwrap(SportDate.from("2027-02-01"))))
    }
    func testFullBackupRestoreKeepsMeasurementsAndNullDraftWritable() async throws {
        let (engine, store, directory) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        let measurements = MeasurementsStore(directory: directory)
        let profile = ProfileStore(directory: directory)
        XCTAssertTrue(measurements.add(date: Date(), weightKg: 80, waistCm: 90, bodyFatPercent: 20))
        profile.profile.name = "Test"
        profile.save()
        let backup = SportFitBackup(engine: engine, measurements: measurements, store: store, profile: profile)
        let id = try XCTUnwrap(measurements.entries.first?.id)
        measurements.delete(id)
        try BackupRestore.restore(backup, engine: engine, measurements: measurements, store: store, profile: profile)
        XCTAssertEqual(measurements.entries.first?.id, id)
        XCTAssertEqual(profile.profile.name, "Test")
        XCTAssertNil(engine.draft)
        XCTAssertTrue(engine.canExport)
        XCTAssertTrue(measurements.canExport)
    }

}
