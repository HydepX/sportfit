import XCTest
@testable import SportFitCore

final class ProgramTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/LegacyData/\(name).v1.json"))
    }
    private func decoded() throws -> (ExerciseCatalog, TrainingProgram) {
        (try JSONDecoder().decode(ExerciseCatalog.self, from: data("exercises")),
         try JSONDecoder().decode(TrainingProgram.self, from: data("program_12w")))
    }
    private func altered(_ mutate: (inout [String: Any]) -> Void) throws -> TrainingProgram {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data("program_12w")) as? [String: Any])
        mutate(&object)
        return try JSONDecoder().decode(TrainingProgram.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testBundledCatalogAndProgram() throws {
        let (catalog, program) = try decoded()
        try DataValidation.program(program, catalog: catalog)
        XCTAssertEqual(catalog.exercises.count, 53)
        XCTAssertEqual(program.startDate, "2026-11-09")
        XCTAssertEqual(program.endDate, "2027-01-31")
        XCTAssertEqual(program.conditionalSubstitutions?["wall_push"]?.fallback, "press_alt")
        XCTAssertEqual(program.conditionalSubstitutions?["march_seated"]?.fallback, "toe_moves")
        XCTAssertNil(program.prescriptions, "Do not invent absent prescriptions")
    }
    func testRejectsUnknownExercise() throws {
        let (catalog, _) = try decoded()
        let program = try altered { object in
            var phases = object["phases"] as! [[String: Any]]
            var days = phases[0]["days"] as! [[String: Any]]
            days[0]["exercise_ids"] = ["missing"]
            phases[0]["days"] = days
            object["phases"] = phases
        }
        XCTAssertThrowsError(try DataValidation.program(program, catalog: catalog))
    }
    func testRejectsOverlappingAndMissingWeeks() throws {
        let (catalog, _) = try decoded()
        for start in [4, 6] {
            let program = try altered { object in
                var phases = object["phases"] as! [[String: Any]]
                phases[1]["week_start"] = start
                object["phases"] = phases
            }
            XCTAssertThrowsError(try DataValidation.program(program, catalog: catalog))
        }
    }
    func testRejectsDateMismatch() throws {
        let (catalog, _) = try decoded()
        let program = try altered { $0["end_date"] = "2027-02-01" }
        XCTAssertThrowsError(try DataValidation.program(program, catalog: catalog))
        XCTAssertNil(SportDate.from("2026-02-30"))
        XCTAssertNil(SportDate.from("2026-11-09junk"))
    }
    func testRejectsBadSubstitution() throws {
        let (catalog, _) = try decoded()
        let program = try altered { $0["conditional_substitutions"] = ["wall_push": ["fallback": "unknown", "reason": "test"]] }
        XCTAssertThrowsError(try DataValidation.program(program, catalog: catalog))
    }
    func testCalendarSpanAcrossTimeZones() throws {
        let (_, program) = try decoded()
        let old = NSTimeZone.default
        defer { NSTimeZone.default = old }
        for zone in ["Asia/Novosibirsk", "America/New_York", "Pacific/Auckland"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = NSTimeZone.default
            formatter.dateFormat = "yyyy-MM-dd"
            let start = try XCTUnwrap(formatter.date(from: program.startDate))
            let end = try XCTUnwrap(formatter.date(from: program.endDate))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = NSTimeZone.default
            XCTAssertEqual(calendar.dateComponents([.day], from: start, to: end).day, 83)
            XCTAssertEqual(calendar.component(.weekday, from: start), 2)
            XCTAssertEqual(calendar.component(.weekday, from: end), 1)
        }
    }
    func testRoundTripRetainsStableIDs() throws {
        let (catalog, program) = try decoded()
        let restored = try JSONDecoder().decode(ExerciseCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(restored.exercises.map(\.id), catalog.exercises.map(\.id))
        try DataValidation.program(JSONDecoder().decode(TrainingProgram.self, from: JSONEncoder().encode(program)), catalog: restored)
    }
    func testActualCalendarBoundariesAnd48Sessions() throws {
        let (_, program) = try decoded()
        let start = try XCTUnwrap(SportDate.from(program.startDate))
        var count = 0
        for offset in 0..<84 {
            let date = try XCTUnwrap(SportDate.calendar.date(byAdding: .day, value: offset, to: start))
            if program.day(on: date) != nil { count += 1 }
        }
        XCTAssertEqual(count, 48)
        XCTAssertNil(program.day(on: try XCTUnwrap(SportDate.from("2026-11-08"))))
        XCTAssertNotNil(program.day(on: try XCTUnwrap(SportDate.from("2027-01-31"))))
        XCTAssertNil(program.day(on: try XCTUnwrap(SportDate.from("2027-02-01"))))
    }

    func testRestoreJournalAndPreRestorePreservation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("profile.v1.json")
        let old = Data("old data".utf8)
        let new = Data("new data".utf8)
        try old.write(to: file)
        try LocalFiles.restore(["profile.v1.json": new], directory: folder)
        XCTAssertEqual(try Data(contentsOf: file), new)
        let previous = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: folder.appendingPathComponent("before-restore.v1.json")))
        XCTAssertEqual(previous["profile.v1.json"], old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("restore-journal.v1.json").path))
        // Simulate termination after the journal was persisted but before files were applied.
        try JSONEncoder().encode(["profile.v1.json": old]).write(to: folder.appendingPathComponent("restore-journal.v1.json"))
        LocalFiles.recoverIfNeeded(directory: folder)
        XCTAssertEqual(try Data(contentsOf: file), old)
        XCTAssertNil(LocalFiles.recoveryError)
    }

    func testRestoreRejectsPathTraversal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try LocalFiles.restore(["../profile.v1.json": Data()], directory: folder))
    }

    func testWorkoutDurationFreezesAtSummaryAndExcludesPause() {
        let now = Date()
        var draft = WorkoutDraft(date: "2026-11-09", programId: "test", title: "test", movements: [])
        draft.elapsedPausedSeconds = 10
        draft.endedAt = draft.startedAt.addingTimeInterval(100)
        XCTAssertEqual(draft.activeSeconds(now: now.addingTimeInterval(500)), 90)
        draft.endedAt = nil
        draft.pauseStartedAt = draft.startedAt.addingTimeInterval(50)
        XCTAssertEqual(draft.activeSeconds(now: draft.startedAt.addingTimeInterval(100)), 40)
    }

    func testLegacyWorkoutDraftDecodesWithoutNewFields() throws {
        let original = WorkoutDraft(date: "2026-11-09", programId: "test", title: "test", movements: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "endedAt")
        json.removeValue(forKey: "pausedPhase")
        let decoded = try JSONDecoder().decode(WorkoutDraft.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertNil(decoded.pausedPhase)
        XCTAssertNil(decoded.endedAt)
    }

    func testMeasurementBMIAndStableIdentity() throws {
        var entry = BodyMeasurement(date: Date(), weightKg: 81, waistCm: 80, bodyFatPercent: 20)
        entry.heightCm = 180
        XCTAssertEqual(try XCTUnwrap(entry.bmi), 25, accuracy: 0.0001)
        let restored = try JSONDecoder().decode(BodyMeasurement.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(restored.id, entry.id)
        XCTAssertEqual(restored.source, "manual")
    }

}
