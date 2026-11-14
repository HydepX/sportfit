import XCTest
@testable import SportFitCore

final class WorkbookProgramTests: XCTestCase {
    private var data: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SportFit/Resources/Data") }
    private func load() throws -> (TrainingProgram, ExerciseCatalog) {
        (try JSONDecoder().decode(TrainingProgram.self, from: Data(contentsOf: data.appendingPathComponent("program_12w_with_sets.v2.json"))),
         try JSONDecoder().decode(ExerciseCatalog.self, from: Data(contentsOf: data.appendingPathComponent("exercises.v1.json"))))
    }
    func testNewWorkbookHas36CurrentExercises48WorkoutsAnd624Assignments() throws {
        let (plan, catalog) = try load(); try DataValidation.program(plan, catalog: catalog)
        XCTAssertEqual(plan.programId, "sportfit_12w_2026q4")
        XCTAssertEqual(catalog.currentExercises.count, 36)
        XCTAssertEqual(catalog.exercises.filter { $0.retired == true }.count, 53)
        XCTAssertEqual(plan.sessions?.count, 48)
        XCTAssertEqual(plan.sessions?.flatMap(\.items).count, 624)
        XCTAssertEqual(Set(plan.sessions?.flatMap(\.items).compactMap(\.sourceItemId) ?? []).count, 624)
        XCTAssertFalse(catalog.currentExercises.contains { $0.id == "press_floor" })
    }
    func testTemplateDatesNeverAdvanceTheNewRun() throws {
        let (plan, _) = try load(); let run = ProgramRun(title: "New", program: plan)
        XCTAssertEqual(run.dayCount, 84); XCTAssertEqual(run.workoutCount, 48)
        XCTAssertEqual(run.currentDay, 0); XCTAssertNil(run.workout(on: 1))
    }
    func testAllFiveSourceUnitTypesAndPerSideDurationSurviveEncoding() throws {
        let (plan, _) = try load(); let restored = try JSONDecoder().decode(TrainingProgram.self, from: JSONEncoder().encode(plan))
        let items = try XCTUnwrap(restored.sessions).flatMap(\.items)
        XCTAssertEqual(Set(items.map(\.mode)), ["duration", "duration_per_side", "repetitions", "repetitions_per_side", "repetitions_total"])
        let side = try XCTUnwrap(items.first { $0.mode == "duration_per_side" })
        XCTAssertEqual(side.targetSeconds, 20); XCTAssertEqual(side.unit, "сек/сторона")
        XCTAssertTrue(side.targetDescription.contains("каждую сторону"))
    }
    func testRepeatedW04UsesItsOwnRowInsteadOfTheWarmupPrescription() throws {
        let (plan, _) = try load()
        let session = try XCTUnwrap(plan.sessions?.first { $0.items.filter { $0.exerciseId == "W04" }.count == 2 })
        let date = try XCTUnwrap(SportDate.from(session.date))
        let positions = session.items.indices.filter { session.items[$0].exerciseId == "W04" }
        let first = try XCTUnwrap(plan.prescription("W04", on: date, position: positions[0]))
        let second = try XCTUnwrap(plan.prescription("W04", on: date, position: positions[1]))
        XCTAssertNotEqual(first.sourceItemId, second.sourceItemId)
        XCTAssertEqual(first.sets, session.items[positions[0]].sets)
        XCTAssertEqual(second.sets, session.items[positions[1]].sets)
        XCTAssertEqual(first.restSeconds, 0)
        XCTAssertGreaterThan(try XCTUnwrap(second.restSeconds), 0)
    }
    func testSecondSideIsRealRecordedTimeAndMissingSideIsPartial() throws {
        let (_, catalog) = try load(); let exercise = try XCTUnwrap(catalog.currentExercises.first { $0.id == "K08" })
        let rule = ExercisePrescription(sets: 1, repetitions: "20 сек на сторону", restSeconds: 50, progression: nil, mode: "duration_per_side", targetSeconds: 20)
        var movement = WorkoutMovement(sourceId: "K08", exercise: exercise, prescription: rule)
        XCTAssertTrue(movement.isTimed); XCTAssertTrue(movement.isTimedPerSide)
        movement.sets = [ActualSet(seconds: 15, completedAt: Date(), otherSideSeconds: 19)]
        let done = WorkoutResult(id: UUID(), date: "2026-11-16", programId: "new", title: "Side", startedAt: Date(), finishedAt: Date(), durationSeconds: 34, feeling: nil, finishedEarly: false, movements: [movement])
        XCTAssertTrue(done.isComplete); XCTAssertEqual(TrainingSummary.make([done]).timedSeconds, 34)
        movement.sets[0].otherSideSeconds = nil
        let partial = WorkoutResult(id: UUID(), date: "2026-11-16", programId: "new", title: "Side", startedAt: Date(), finishedAt: Date(), durationSeconds: 15, feeling: nil, finishedEarly: false, movements: [movement])
        XCTAssertFalse(partial.isComplete); XCTAssertEqual(TrainingSummary.make([partial]).timedSeconds, 15)
    }
}
