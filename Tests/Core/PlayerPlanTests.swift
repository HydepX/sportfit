import XCTest
@testable import SportFitCore

final class PlayerPlanTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func catalog() throws -> ExerciseCatalog { try JSONDecoder().decode(ExerciseCatalog.self, from: Data(contentsOf: root.appendingPathComponent("SportFit/Resources/Data/exercises.v1.json"))) }
    func testExactPlanDefaultsUseTargetsRatherThanOriginalHintRanges() throws {
        let catalog = try catalog()
        let plan = try JSONDecoder().decode(TrainingProgram.self, from: Data(contentsOf: root.appendingPathComponent("SportFit/Resources/Data/program_12w_with_sets.v2.json")))
        let date = try XCTUnwrap(SportDate.from("2026-11-09"))
        let breath = try XCTUnwrap(catalog.exercises.first { $0.id == "wu_breath" })
        let press = try XCTUnwrap(catalog.exercises.first { $0.id == "press_floor" })
        XCTAssertEqual(WorkoutMovement(sourceId: breath.id, exercise: breath, prescription: plan.prescription(breath.id, on: date)).plannedSeconds, 30)
        XCTAssertEqual(WorkoutMovement(sourceId: press.id, exercise: press, prescription: plan.prescription(press.id, on: date)).plannedReps, 10)
    }
    func testOldDraftWithoutTimerFieldsRetainsUUIDAndActualSets() throws {
        let exercise = try XCTUnwrap(catalog().exercises.first { $0.id == "wu_breath" })
        var movement = WorkoutMovement(sourceId: exercise.id, exercise: exercise)
        movement.sets = [ActualSet(reps: nil, weightKg: nil, seconds: 24, completedAt: Date())]
        let draft = WorkoutDraft(date: "2026-11-09", programId: "test", title: "Old", movements: [movement])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        for key in ["guided", "exerciseEndsAt", "exerciseSecondsLeft", "autoplaySuspended"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(WorkoutDraft.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.guided)
        XCTAssertEqual(decoded.id, draft.id)
        XCTAssertEqual(decoded.movements[0].sets[0].id, movement.sets[0].id)
        XCTAssertEqual(decoded.movements[0].sets[0].seconds, 24)
    }
    func testAmbiguousLegacyDurationDoesNotInventACountdown() throws {
        let exercise = try XCTUnwrap(catalog().exercises.first { $0.id == "wu_breath" })
        let movement = WorkoutMovement(sourceId: exercise.id, exercise: exercise)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(movement)) as? [String: Any])
        json["target"] = "30–40 сек"
        let ambiguous = try JSONDecoder().decode(WorkoutMovement.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(ambiguous.plannedSeconds)
        json["target"] = "2 мин"
        let minutes = try JSONDecoder().decode(WorkoutMovement.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(minutes.plannedSeconds, 120)
    }
}
