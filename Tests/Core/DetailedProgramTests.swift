import XCTest
@testable import SportFitCore

final class DetailedProgramTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func load() throws -> (TrainingProgram, ExerciseCatalog) {
        let folder = root.appendingPathComponent("Tests/Fixtures/LegacyData")
        return (try JSONDecoder().decode(TrainingProgram.self, from: Data(contentsOf: folder.appendingPathComponent("program_12w_with_sets.v2.json"))),
                try JSONDecoder().decode(ExerciseCatalog.self, from: Data(contentsOf: folder.appendingPathComponent("exercises.v1.json"))))
    }
    func testAll48DatedSessionsAnd984PrescriptionsDecode() throws {
        let (program, catalog) = try load()
        try DataValidation.program(program, catalog: catalog)
        XCTAssertEqual(program.sessions?.count, 48)
        XCTAssertEqual(program.sessions?.flatMap(\.items).count, 984)
        XCTAssertEqual(program.phases.count, 3)
        for session in try XCTUnwrap(program.sessions) {
            let date = try XCTUnwrap(SportDate.from(session.date))
            XCTAssertEqual(program.day(on: date)?.exerciseIds, session.items.map(\.exerciseId))
            for item in session.items {
                let exercise = try XCTUnwrap(catalog.exercises.first { $0.id == item.exerciseId })
                let movement = WorkoutMovement(sourceId: item.exerciseId, exercise: exercise, prescription: item.prescription)
                XCTAssertEqual(movement.prescription?.sets, item.sets)
                XCTAssertEqual(movement.prescription?.restSeconds, item.restSeconds)
                XCTAssertEqual(movement.isTimed, item.mode == "duration")
                XCTAssertEqual(movement.prescription?.targetReps, item.targetReps)
                XCTAssertEqual(movement.prescription?.targetSeconds, item.targetSeconds)
            }
        }
    }
    func testSourceMetadataAndEveryAssignmentSurviveEncoding() throws {
        let path = root.appendingPathComponent("Tests/Fixtures/LegacyData/program_12w_with_sets.v2.json")
        let raw = try Data(contentsOf: path)
        let program = try JSONDecoder().decode(TrainingProgram.self, from: raw)
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(program)) as? [String: Any])
        encoded.removeValue(forKey: "phases") // Generated overview; precise sessions remain the source of truth.
        XCTAssertTrue(NSDictionary(dictionary: source).isEqual(to: encoded))
    }

    func testWeeklyProgressionIsNotFlattened() throws {
        let (program, _) = try load()
        let first = try XCTUnwrap(program.sessions?.first { $0.date == "2026-11-09" }?.items.first { $0.exerciseId == "press_floor" })
        let second = try XCTUnwrap(program.sessions?.first { $0.date == "2026-11-16" }?.items.first { $0.exerciseId == "press_floor" })
        XCTAssertEqual(first.sets, 1)
        XCTAssertEqual(second.sets, 2)
    }
    func testModesAndClearanceSurviveBackupRoundTrip() throws {
        let (program, _) = try load()
        let restored = try JSONDecoder().decode(TrainingProgram.self, from: JSONEncoder().encode(program))
        let items = try XCTUnwrap(restored.sessions).flatMap(\.items)
        XCTAssertEqual(Set(items.map(\.mode)), ["duration", "repetitions", "repetitions_per_side", "breath_cycles"])
        let conditional = items.filter { $0.requiresClearance == true }
        XCTAssertEqual(conditional.count, 12)
        XCTAssertTrue(conditional.allSatisfy { $0.clearanceNote?.contains("иначе пропустить") == true })
        XCTAssertNil(restored.conditionalSubstitutions, "The supplied v2 says skip without substitution")
    }
    func testActualFourRepetitionsDoesNotOverwritePlannedFive() throws {
        let (_, catalog) = try load()
        let exercise = try XCTUnwrap(catalog.exercises.first { $0.id == "press_floor" })
        let rule = ExercisePrescription(sets: 1, repetitions: "5 повторений", restSeconds: 60, progression: nil,
                                        mode: "repetitions", targetReps: 5)
        var movement = WorkoutMovement(sourceId: exercise.id, exercise: exercise, prescription: rule)
        movement.sets.append(ActualSet(reps: 4, weightKg: 0, seconds: nil, completedAt: Date()))
        let restored = try JSONDecoder().decode(WorkoutMovement.self, from: JSONEncoder().encode(movement))
        XCTAssertEqual(restored.prescription?.targetReps, 5)
        XCTAssertEqual(restored.sets.first?.reps, 4)
        XCTAssertEqual(restored.target, "5 повторений")
    }
    func testRejectsMissingTimeTargetAndDuplicateSessionDate() throws {
        let (program, catalog) = try load()
        let raw = try JSONEncoder().encode(program)
        for duplicate in [false, true] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            var sessions = json["sessions"] as! [[String: Any]]
            if duplicate { sessions[1]["date"] = sessions[0]["date"] }
            else {
                var items = sessions[0]["items"] as! [[String: Any]]
                items[0].removeValue(forKey: "target_seconds")
                sessions[0]["items"] = items
            }
            json["sessions"] = sessions
            let invalid = try JSONDecoder().decode(TrainingProgram.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try DataValidation.program(invalid, catalog: catalog))
        }
    }
    func testHistoryDefaultsToSevenCalendarDaysAndCustomIncludesWholeEndDay() throws {
        let now = try XCTUnwrap(SportDate.from("2026-11-23")) .addingTimeInterval(12 * 3600)
        let filter = HistoryFilter()
        XCTAssertTrue(filter.contains(try XCTUnwrap(SportDate.from("2026-11-17")), now: now))
        XCTAssertFalse(filter.contains(try XCTUnwrap(SportDate.from("2026-11-16")), now: now))
        XCTAssertFalse(filter.contains(now.addingTimeInterval(1), now: now))
        let custom = HistoryFilter(period: .custom, start: try XCTUnwrap(SportDate.from("2026-11-09")), end: try XCTUnwrap(SportDate.from("2026-11-11")))
        XCTAssertTrue(custom.contains(try XCTUnwrap(SportDate.from("2026-11-11")).addingTimeInterval(23 * 3600), now: now))
        XCTAssertFalse(custom.contains(try XCTUnwrap(SportDate.from("2026-11-12")), now: now))
    }
}
