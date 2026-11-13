import XCTest
@testable import SportFit

@MainActor final class GuidedWorkoutTests: XCTestCase {
    private func setup(_ ids: [String] = ["wu_breath", "wu_neck"]) throws -> (WorkoutEngine, FitnessStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FitnessStore(directory: directory), engine = WorkoutEngine(directory: directory)
        engine.start(day: ProgramDay(dayOfWeek: "test", name: "Guided", exerciseIds: ids), date: try XCTUnwrap(SportDate.from("2026-11-09")), store: store, guided: true)
        return (engine, store, directory)
    }
    func testThirtySecondCountdownRecordsOnceAndZeroRestWaitsForUser() async throws {
        let (engine, _, directory) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(engine.draft?.phase, .active)
        let end = try XCTUnwrap(engine.draft?.exerciseEndsAt)
        XCTAssertEqual(engine.exerciseRemaining(now: end.addingTimeInterval(-30)), 30)
        XCTAssertEqual(engine.exerciseRemaining(now: end.addingTimeInterval(-1)), 1)
        XCTAssertEqual(engine.exerciseRemaining(now: end), 0)
        engine.tick(now: end)
        XCTAssertEqual(engine.draft?.phase, .rest)
        XCTAssertEqual(engine.draft?.movements[0].sets.first?.seconds, 30)
        for _ in 0..<5 { engine.tick(now: end.addingTimeInterval(300)) }
        XCTAssertEqual(engine.draft?.completedSetCount, 1)
        XCTAssertEqual(engine.draft?.currentIndex, 0)
        engine.continueAfterRest(now: end.addingTimeInterval(300))
        XCTAssertEqual(engine.draft?.currentIndex, 1)
        XCTAssertEqual(engine.draft?.phase, .active)
        XCTAssertEqual(engine.exerciseRemaining(now: end.addingTimeInterval(300)), 30)
    }
    func testPauseFreezesCountdownAcrossRelaunch() async throws {
        let (engine, _, directory) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        engine.pause()
        let left = try XCTUnwrap(engine.draft?.exerciseSecondsLeft)
        XCTAssertNil(engine.draft?.exerciseEndsAt)
        let loaded = WorkoutEngine(directory: directory)
        XCTAssertEqual(loaded.draft?.phase, .paused)
        XCTAssertEqual(loaded.exerciseRemaining(now: Date().addingTimeInterval(3600)), left)
        loaded.resume()
        let end = try XCTUnwrap(loaded.draft?.exerciseEndsAt)
        XCTAssertEqual(loaded.exerciseRemaining(now: end.addingTimeInterval(-Double(left))), left)
    }
    func testRelaunchAfterExpiryDoesNotReplayUnseenExercises() async throws {
        let (engine, _, directory) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        var draft = try XCTUnwrap(engine.draft)
        draft.exerciseEndsAt = Date().addingTimeInterval(-3600)
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent("active_workout.v1.json"))
        let loaded = WorkoutEngine(directory: directory)
        XCTAssertEqual(loaded.draft?.phase, .rest)
        XCTAssertEqual(loaded.draft?.completedSetCount, 1)
        loaded.tick(now: Date().addingTimeInterval(7200))
        XCTAssertEqual(loaded.draft?.currentIndex, 0)
        XCTAssertEqual(loaded.draft?.completedSetCount, 1)
    }
    func testPlannedRepsRestExtensionAndAutomaticNextExercise() async throws {
        let (engine, _, directory) = try setup(["press_floor", "wu_neck"]); defer { try? FileManager.default.removeItem(at: directory) }
        engine.completePlanned()
        XCTAssertEqual(engine.draft?.movements[0].sets.first?.reps, 10)
        let original = try XCTUnwrap(engine.draft?.restEndsAt)
        engine.extendRest(30, now: original.addingTimeInterval(20))
        let extended = try XCTUnwrap(engine.draft?.restEndsAt)
        XCTAssertEqual(extended, original.addingTimeInterval(50))
        engine.tick(now: extended)
        XCTAssertEqual(engine.draft?.currentIndex, 1)
        XCTAssertEqual(engine.draft?.phase, .active)
        XCTAssertEqual(engine.exerciseRemaining(now: extended), 30)
    }
    func testRepeatReplacesOnlyLastDraftSetAndSummaryCorrectionIsSaved() async throws {
        let (engine, _, directory) = try setup(["wu_breath"]); defer { try? FileManager.default.removeItem(at: directory) }
        let end = try XCTUnwrap(engine.draft?.exerciseEndsAt)
        engine.tick(now: end)
        engine.pause(); engine.restartCurrentSet()
        XCTAssertEqual(engine.draft?.completedSetCount, 0)
        XCTAssertEqual(engine.draft?.phase, .active)
        let restarted = try XCTUnwrap(engine.draft?.exerciseEndsAt)
        engine.tick(now: restarted)
        engine.continueAfterRest()
        XCTAssertEqual(engine.draft?.phase, .summary)
        let id = try XCTUnwrap(engine.draft?.movements[0].sets.first?.id)
        engine.editSet(id, reps: nil, weight: nil, seconds: 24)
        let result = try XCTUnwrap(engine.finish(feeling: nil))
        XCTAssertEqual(result.movements[0].prescription?.targetSeconds, 30)
        XCTAssertEqual(result.movements[0].sets.first?.seconds, 24)
        XCTAssertEqual(TrainingSummary.make(WorkoutEngine(directory: directory).history).timedSeconds, 24)
    }
    func testRestEditDoesNotChangePlanAndPausedRestCanBeExtended() async throws {
        let (engine, _, directory) = try setup(["press_floor"]); defer { try? FileManager.default.removeItem(at: directory) }
        engine.completePlanned(); engine.pause()
        let before = try XCTUnwrap(engine.draft?.restSecondsLeft)
        engine.extendRest(30)
        XCTAssertEqual(engine.draft?.restSecondsLeft, before + 30)
        let id = try XCTUnwrap(engine.draft?.movements[0].sets.first?.id)
        engine.editSet(id, reps: 4, weight: 2, seconds: nil)
        XCTAssertEqual(engine.draft?.movements[0].prescription?.targetReps, 10)
        XCTAssertEqual(engine.draft?.movements[0].sets.first?.reps, 4)
        engine.resume(); XCTAssertEqual(engine.draft?.phase, .rest)
    }
    func testLegacyFinishedSetIsNotCountedAgainWhenOpeningNewPlayer() async throws {
        let (engine, store, directory) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        engine.discard()
        engine.start(day: ProgramDay(dayOfWeek: "test", name: "Legacy", exerciseIds: ["wu_breath"]), date: try XCTUnwrap(SportDate.from("2026-11-09")), store: store)
        engine.begin(); engine.complete(reps: nil, weight: nil, seconds: 23)
        let id = engine.draft?.id
        engine.enableGuidedMode()
        XCTAssertEqual(engine.draft?.id, id)
        XCTAssertEqual(engine.draft?.phase, .rest)
        XCTAssertEqual(engine.draft?.completedSetCount, 1)
        XCTAssertEqual(engine.draft?.movements[0].sets.first?.seconds, 23)
    }
    func testGuidedStartStillRequiresExplicitMedicalClearance() async throws {
        let (engine, store, directory) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        engine.discard()
        engine.start(day: ProgramDay(dayOfWeek: "test", name: "Clearance", exerciseIds: ["wall_push"]), date: try XCTUnwrap(SportDate.from("2026-12-07")), store: store, guided: true)
        XCTAssertEqual(engine.draft?.phase, .prepare)
        XCTAssertNil(engine.draft?.exerciseEndsAt)
        engine.begin(clearanceConfirmed: true)
        XCTAssertEqual(engine.draft?.phase, .active)
    }
    func testRestAdvancesThroughPrescribedSetsBeforeChangingExercise() async throws {
        let (engine, store, directory) = try setup(); defer { try? FileManager.default.removeItem(at: directory) }
        engine.discard()
        engine.start(day: ProgramDay(dayOfWeek: "test", name: "Multiple sets", exerciseIds: ["press_floor", "wu_neck"]), date: try XCTUnwrap(SportDate.from("2026-12-07")), store: store, guided: true)
        let count = try XCTUnwrap(engine.draft?.movements[0].prescription?.sets)
        XCTAssertGreaterThan(count, 1)
        var now = Date()
        for index in 0..<count {
            now = now.addingTimeInterval(2)
            engine.completePlanned(now: now)
            XCTAssertEqual(engine.draft?.movements[0].sets.count, index + 1)
            let deadline = try XCTUnwrap(engine.draft?.restEndsAt)
            engine.tick(now: deadline)
            XCTAssertEqual(engine.draft?.currentIndex, index == count - 1 ? 1 : 0)
            now = deadline
        }
        XCTAssertEqual(engine.draft?.phase, .active)
    }

}
