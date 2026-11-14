import Foundation

/// Retire the old selectable plan without rewriting completed results or losing drafts.
@MainActor enum PlanReplacement {
    static let programID = "sportfit_12w_2026q4"
    static let retiredIDs: Set<String> = ["fitness_12w_2026_11_09"]
    static func apply(directory: URL, catalog bundled: ExerciseCatalog, program bundledProgram: TrainingProgram) throws {
        guard bundledProgram.programId == programID else { return } // Explicit legacy regression-test bundles.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func read<T: Decodable>(_ type: T.Type, _ name: String, _ fallback: T) throws -> T {
            if FileManager.default.fileExists(atPath: url(name).path) { return try JSONDecoder().decode(type, from: Data(contentsOf: url(name))) }
            return fallback
        }
        func bytes<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
        let first = !FileManager.default.fileExists(atPath: url("plan_release.v1.json").path)
        let oldCatalog = try read(ExerciseCatalog?.self, "exercises.v1.json", nil)
        if let oldCatalog { try DataValidation.catalog(oldCatalog) }
        var local = Dictionary(uniqueKeysWithValues: (oldCatalog?.exercises ?? []).map { ($0.id, $0) })
        var combined: [Exercise] = []
        for entry in bundled.exercises {
            if entry.retired == true, var historical = local.removeValue(forKey: entry.id) {
                historical.retired = true; combined.append(historical)
            } else if !first, entry.retired != true, let existing = local.removeValue(forKey: entry.id) {
                combined.append(existing)
            } else { local.removeValue(forKey: entry.id); combined.append(entry) }
        }
        combined += local.values.sorted { $0.id < $1.id }
        let catalog = ExerciseCatalog(schemaVersion: "1.0.0", exerciseCount: combined.count, exercises: combined)
        try DataValidation.catalog(catalog)
        let oldProgram = try read(TrainingProgram?.self, "program_12w.v1.json", nil)
        let replace = first || oldProgram == nil || retiredIDs.contains(oldProgram!.programId)
        let current = replace ? bundledProgram : oldProgram!
        try DataValidation.program(current, catalog: catalog)
        var archive = try read([TrainingProgram].self, "program_archive.v1.json", [])
        if first, let oldProgram, !retiredIDs.contains(oldProgram.programId), oldProgram.programId != programID { archive.append(oldProgram) }
        archive.removeAll { retiredIDs.contains($0.programId) }
        var idsToRetire = retiredIDs
        if replace, let oldProgram, oldProgram.programId != programID { idsToRetire.insert(oldProgram.programId) }
        var runs = try read([ProgramRun].self, "program_runs.v1.json", [])
        let now = Date()
        for index in runs.indices where idsToRetire.contains(runs[index].program.programId) && !runs[index].isRetired {
            runs[index].retiredAt = now
        }
        try ProgramRun.validate(runs, catalog: catalog)
        var journal = try read(JournalData.self, "journal.v1.json", JournalData())
        try journal.validate()
        let draft = try read(WorkoutDraft?.self, "active_workout.v1.json", nil)
        var clearDraft = false
        if let draft, idsToRetire.contains(draft.programId) {
            let history = try WorkoutDatabase(directory: directory).load()
            if !history.contains(where: { $0.id == draft.id }), !(journal.retiredDrafts ?? []).contains(where: { $0.id == draft.id }) {
                journal.retiredDrafts = (journal.retiredDrafts ?? []) + [draft]
            }
            clearDraft = true
        }
        try journal.validate()
        var files: [String: Data] = [:]
        func changed<T: Encodable>(_ value: T, file: String) throws {
            let next = try bytes(value)
            if (try? Data(contentsOf: url(file))) != next { files[file] = next }
        }
        try changed(catalog, file: "exercises.v1.json")
        try changed(current, file: "program_12w.v1.json")
        try changed(archive, file: "program_archive.v1.json")
        if !runs.isEmpty { try changed(runs, file: "program_runs.v1.json") }
        if clearDraft {
            try changed(journal, file: "journal.v1.json")
            files["active_workout.v1.json"] = try bytes(Optional<WorkoutDraft>.none)
        }
        if first { files["plan_release.v1.json"] = try bytes(programID) }
        if !files.isEmpty { try LocalFiles.restore(files, directory: directory) }
    }
}
