import XCTest
@testable import SportFit

@MainActor final class WorkbookIntegrationTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder
    }
    func testReplacementPreservesCompletedHistoryAndFreezesOldPausedDraftWithoutFakingCompletion() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let oldStore = LegacyFixture.store(directory: folder), engine = WorkoutEngine(directory: folder), profile = ProfileStore(directory: folder)
        profile.profile.name = "Synthetic"; profile.save()
        profile.startRun(title: "Old level", program: try XCTUnwrap(oldStore.program), catalog: try XCTUnwrap(oldStore.catalog), draft: nil)
        let oldRun = try XCTUnwrap(profile.activeRun)
        engine.start(run: oldRun, store: oldStore); engine.begin(); engine.complete(reps: nil, weight: nil, seconds: 23); engine.earlyFinish()
        let finished = try XCTUnwrap(engine.finish(feeling: nil))
        engine.start(run: oldRun, store: oldStore); engine.begin(); engine.complete(reps: nil, weight: nil, seconds: 17); engine.pause()
        let original = try XCTUnwrap(engine.draft)
        let measurements = MeasurementsStore(directory: folder)
        XCTAssertTrue(measurements.add(date: Date(), weightKg: 80, waistCm: nil, bodyFatPercent: nil))
        let current = FitnessStore(directory: folder)
        XCTAssertEqual(current.program?.programId, PlanReplacement.programID)
        XCTAssertEqual(current.catalog?.currentExercises.count, 36)
        XCTAssertTrue(current.archivedPrograms.isEmpty)
        let restored = WorkoutEngine(directory: folder), journal = JournalStore(directory: folder), afterProfile = ProfileStore(directory: folder)
        XCTAssertNil(restored.draft); XCTAssertEqual(restored.history.map(\.id), [finished.id])
        XCTAssertEqual(restored.history[0].movements[0].sets[0].seconds, 23)
        XCTAssertNil(afterProfile.activeRun); XCTAssertTrue(try XCTUnwrap(afterProfile.runs.first).isRetired)
        XCTAssertNil(afterProfile.runs.first?.closedAt, "Retirement is not completion")
        XCTAssertEqual(journal.data.retiredDrafts?.first?.id, original.id)
        XCTAssertEqual(journal.data.retiredDrafts?.first?.movements[0].sets[0].seconds, 17)
        XCTAssertEqual(journal.data.retiredDrafts?.first?.phase, .paused)
        XCTAssertEqual(afterProfile.profile.name, "Synthetic")
        XCTAssertEqual(MeasurementsStore(directory: folder).entries.count, 1)
        let bytes = try Data(contentsOf: folder.appendingPathComponent("journal.v1.json"))
        current.reload(); XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("journal.v1.json")), bytes)
        let backup = SportFitBackup(engine: restored, measurements: measurements, store: current, profile: afterProfile, journal: journal)
        try BackupRestore.validate(try BackupEnvelope.decode(BackupEnvelope.encode(backup)), fallback: current.catalog)
    }
    func testCorruptJournalBlocksReplacementAndLeavesOriginalPlanUntouched() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        _ = LegacyFixture.store(directory: folder)
        let file = folder.appendingPathComponent("program_12w.v1.json")
        try Data(contentsOf: LegacyFixture.assets.appendingPathComponent("program_12w_with_sets.v2.json")).write(to: file)
        let original = try Data(contentsOf: file)
        try Data("broken".utf8).write(to: folder.appendingPathComponent("journal.v1.json"))
        let current = FitnessStore(directory: folder)
        XCTAssertFalse(current.canExport)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testRestoringOldBackupKeepsItsHistoryWithoutReturningRemovedPlanToSelection() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let oldStore = LegacyFixture.store(directory: folder), engine = WorkoutEngine(directory: folder)
        let profile = ProfileStore(directory: folder), measurements = MeasurementsStore(directory: folder), journal = JournalStore(directory: folder)
        profile.startRun(title: "Old backup", program: try XCTUnwrap(oldStore.program), catalog: try XCTUnwrap(oldStore.catalog), draft: nil)
        engine.start(run: try XCTUnwrap(profile.activeRun), store: oldStore)
        engine.begin(); engine.complete(reps: nil, weight: nil, seconds: 13); engine.pause()
        let draftID = try XCTUnwrap(engine.draft?.id)
        let oldBackup = try BackupEnvelope.decode(BackupEnvelope.encode(SportFitBackup(engine: engine, measurements: measurements, store: oldStore, profile: profile, journal: journal)))
        let current = FitnessStore(directory: folder)
        engine.reload(); profile.reload(); journal.reload()
        try BackupRestore.restore(oldBackup, engine: engine, measurements: measurements, store: current, profile: profile, journal: journal)
        XCTAssertEqual(current.program?.programId, PlanReplacement.programID)
        XCTAssertTrue(current.archivedPrograms.isEmpty); XCTAssertNil(profile.activeRun); XCTAssertNil(engine.draft)
        XCTAssertEqual(journal.data.retiredDrafts?.first?.id, draftID)
        XCTAssertEqual(journal.data.retiredDrafts?.first?.movements[0].sets[0].seconds, 13)
        XCTAssertTrue(current.canExport)
        try BackupRestore.validate(SportFitBackup(engine: engine, measurements: measurements, store: current, profile: profile, journal: journal), fallback: current.catalog)
    }
    func testTwoSidesCountDownSeparatelyAndPersistOnPause() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = FitnessStore(directory: folder), engine = WorkoutEngine(directory: folder)
        let session = try XCTUnwrap(store.program?.sessions?.first { $0.items.contains { $0.exerciseId == "K08" } })
        engine.start(day: ProgramDay(dayOfWeek: session.day, name: "Side", exerciseIds: ["K08"]), date: try XCTUnwrap(SportDate.from(session.date)), store: store, guided: true)
        let first = try XCTUnwrap(engine.draft?.exerciseEndsAt); engine.tick(now: first)
        XCTAssertEqual(engine.draft?.currentSide, 2); XCTAssertEqual(engine.draft?.completedSetCount, 0)
        XCTAssertEqual(engine.exerciseRemaining(now: first), 20)
        engine.pause(); let resumed = WorkoutEngine(directory: folder)
        XCTAssertEqual(resumed.draft?.firstSideSeconds, 20); XCTAssertEqual(resumed.draft?.currentSide, 2)
        resumed.resume(); let second = try XCTUnwrap(resumed.draft?.exerciseEndsAt); resumed.tick(now: second)
        let actual = try XCTUnwrap(resumed.draft?.movements[0].sets.first)
        XCTAssertEqual(actual.seconds, 20); XCTAssertEqual(actual.otherSideSeconds, 20)
        XCTAssertEqual(resumed.draft?.completedSetCount, 1); XCTAssertEqual(resumed.draft?.phase, .rest)
        XCTAssertEqual(actual.totalSeconds, 40)
    }
    func testWorkbookRepeatedMovementKeepsBothAssignmentsInEngine() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = FitnessStore(directory: folder), engine = WorkoutEngine(directory: folder)
        let session = try XCTUnwrap(store.program?.sessions?.first { $0.items.filter { $0.exerciseId == "W04" }.count == 2 })
        engine.start(day: ProgramDay(dayOfWeek: session.day, name: session.name, exerciseIds: session.items.map(\.exerciseId)), date: try XCTUnwrap(SportDate.from(session.date)), store: store, guided: true)
        let rows = try XCTUnwrap(engine.draft).movements.filter { $0.exerciseId == "W04" }
        XCTAssertEqual(rows.count, 2); XCTAssertNotEqual(rows[0].id, rows[1].id)
        XCTAssertEqual(rows.map { $0.prescription?.sourceItemId }, session.items.filter { $0.exerciseId == "W04" }.map { $0.sourceItemId })
        XCTAssertNotEqual(rows[0].prescription?.restSeconds, rows[1].prescription?.restSeconds)
    }
}
