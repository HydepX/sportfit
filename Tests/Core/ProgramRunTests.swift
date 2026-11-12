import XCTest
@testable import SportFitCore

final class ProgramRunTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func program() throws -> TrainingProgram {
        try JSONDecoder().decode(TrainingProgram.self, from: Data(contentsOf: root.appendingPathComponent("SportFit/Resources/Data/program_12w_with_sets.v2.json")))
    }
    private func result(run: ProgramRun, index: Int, complete: Bool) throws -> WorkoutResult {
        let catalog = try JSONDecoder().decode(ExerciseCatalog.self, from: Data(contentsOf: root.appendingPathComponent("SportFit/Resources/Data/exercises.v1.json")))
        let exercise = try XCTUnwrap(catalog.exercises.first)
        var movement = WorkoutMovement(sourceId: exercise.id, exercise: exercise)
        if complete { movement.sets = [ActualSet(reps: 4, weightKg: 0, seconds: nil, completedAt: Date())] }
        return WorkoutResult(id: UUID(), date: SportDate.key(Date()), programId: run.program.programId,
                             title: "Test", startedAt: Date(), finishedAt: Date(), durationSeconds: 0, feeling: nil,
                             finishedEarly: !complete, movements: [movement], runId: run.id, runDayIndex: index)
    }
    func testSequentialDaysPreserveAll48SessionsAnd984Assignments() throws {
        let run = ProgramRun(title: "Test", program: try program())
        XCTAssertEqual(run.dayCount, 84)
        XCTAssertEqual(run.workoutCount, 48)
        XCTAssertEqual(run.currentDay, 0)
        XCTAssertNil(run.workout(on: 1))
        XCTAssertEqual(run.workout(on: 0)?.exerciseIds, run.program.sessions?.first?.items.map(\.exerciseId))
        var assignments = 0
        for index in 0..<run.dayCount {
            guard let day = run.workout(on: index), let source = run.sourceDate(for: index) else { continue }
            assignments += day.exerciseIds.count
            for id in day.exerciseIds {
                XCTAssertNotNil(run.program.prescription(id, on: source))
            }
        }
        XCTAssertEqual(assignments, 984)
        XCTAssertNil(run.sourceDate(for: -1))
        XCTAssertNil(run.sourceDate(for: 84))
    }
    func testCalendarTimeNeverAdvancesProgressOrCreatesMisses() throws {
        let run = ProgramRun(title: "Test", program: try program())
        let restored = try JSONDecoder().decode(ProgramRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(restored.currentDay, 0)
        XCTAssertNil(restored.outcome(on: 0, history: []))
        XCTAssertEqual(restored.completedDayCount, 0)
    }
    func testSkipRequiresConfirmationAndRestClosesWithoutResult() throws {
        var run = ProgramRun(title: "Test", program: try program())
        XCTAssertThrowsError(try run.closeDay(history: [], allowIncomplete: false))
        XCTAssertEqual(run.currentDay, 0)
        try run.closeDay(history: [], allowIncomplete: true)
        XCTAssertEqual(run.days[0].outcome, .skipped)
        XCTAssertEqual(run.currentDay, 1)
        try run.closeDay(history: [], allowIncomplete: false)
        XCTAssertEqual(run.days[1].outcome, .rest)
        XCTAssertEqual(run.currentDay, 2)
    }
    func testPartialDayDoesNotBecomeCompleteOnClosure() throws {
        var run = ProgramRun(title: "Test", program: try program())
        let partial = try result(run: run, index: 0, complete: false)
        XCTAssertEqual(run.outcome(on: 0, history: [partial]), .partial)
        XCTAssertThrowsError(try run.closeDay(history: [partial], allowIncomplete: false))
        try run.closeDay(history: [partial], allowIncomplete: true)
        XCTAssertEqual(run.days[0].outcome, .partial)
        XCTAssertEqual(run.completedWorkoutCount, 0)
    }
    func testRetryKeepsBothAttemptsAndUsesCompleteResult() throws {
        var run = ProgramRun(title: "Test", program: try program())
        let history = [try result(run: run, index: 0, complete: false), try result(run: run, index: 0, complete: true)]
        XCTAssertEqual(run.results(on: 0, history: history).count, 2)
        XCTAssertEqual(run.outcome(on: 0, history: history), .completed)
        try run.closeDay(history: history, allowIncomplete: false)
        XCTAssertEqual(run.currentDay, 1)
        XCTAssertEqual(run.completedWorkoutCount, 1)
    }
    func testRepeatedRunDoesNotInheritPreviousResults() throws {
        let first = ProgramRun(title: "First", program: try program())
        let second = ProgramRun(title: "Second", program: first.program)
        let history = [try result(run: first, index: 0, complete: true)]
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.results(on: 0, history: history).count, 0)
        XCTAssertNil(second.outcome(on: 0, history: history))
    }
    func testClosingIncompleteLevelRequiresConfirmationAndFreezesProgress() throws {
        var run = ProgramRun(title: "Test", program: try program())
        XCTAssertThrowsError(try run.close(allowIncomplete: false))
        try run.close(allowIncomplete: true)
        XCTAssertNotNil(run.closedAt)
        XCTAssertThrowsError(try run.closeDay(history: [], allowIncomplete: true))
        XCTAssertEqual(run.days.count, 0)
    }
    func testEntireProgramCanBeClosedWithoutInventingCompletions() throws {
        var run = ProgramRun(title: "Test", program: try program())
        for _ in 0..<84 { try run.closeDay(history: [], allowIncomplete: true) }
        XCTAssertNil(run.currentDay)
        XCTAssertEqual(run.days.filter { $0.outcome == .skipped }.count, 48)
        XCTAssertEqual(run.days.filter { $0.outcome == .rest }.count, 36)
        XCTAssertEqual(run.completedWorkoutCount, 0)
        XCTAssertThrowsError(try run.closeDay(history: [], allowIncomplete: true))
        XCTAssertThrowsError(try run.close(allowIncomplete: false))
        try run.close(allowIncomplete: true)
    }
    func testValidationRejectsJumpingAheadAndMultipleActiveLevels() throws {
        var run = ProgramRun(title: "Test", program: try program())
        run.days = [RunDayClosure(dayIndex: 2, outcome: .completed, closedAt: Date())]
        XCTAssertThrowsError(try run.validateStructure())
        run.days = [RunDayClosure(dayIndex: 0, outcome: .rest, closedAt: Date())]
        XCTAssertThrowsError(try run.validateStructure())
        let catalog = try JSONDecoder().decode(ExerciseCatalog.self, from: Data(contentsOf: root.appendingPathComponent("SportFit/Resources/Data/exercises.v1.json")))
        let first = ProgramRun(title: "First", program: try program())
        XCTAssertThrowsError(try ProgramRun.validate([first, first], catalog: catalog))
        XCTAssertThrowsError(try ProgramRun.validate([first, ProgramRun(title: "Second", program: first.program)], catalog: catalog))
    }
    func testSnapshotAndExtraRestSurviveRoundTripWithoutAdvancingDay() throws {
        var run = ProgramRun(title: "Test", program: try program())
        run.extraRests.append(Date())
        let restored = try JSONDecoder().decode(ProgramRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(restored.currentDay, 0)
        XCTAssertEqual(restored.extraRests.count, 1)
        XCTAssertEqual(restored.program.sessions?.flatMap(\.items).count, 984)
    }
}
