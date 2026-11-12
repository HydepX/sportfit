import Foundation

/// A durable redo journal makes multi-file restore recoverable after termination.
/// The previous files are kept as a local pre-restore backup until the next restore.
enum LocalFiles {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var recoveryError: String?
    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private static let journal = "restore-journal.v1.json"
    private static let permitted: Set<String> = [
        "exercises.v1.json", "program_12w.v1.json", "program_archive.v1.json",
        "completed_sets.json", "active_workout.v1.json", "workout_history.v1.json",
        "body_measurements.v1.json", "profile.v1.json", "schedule.v1.json", "program_runs.v1.json"
    ]
    static func restore(_ files: [String: Data], directory: URL = LocalFiles.directory) throws {
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        try DataValidation.require(!FileManager.default.fileExists(atPath: url(journal).path), "Сначала заверши предыдущее восстановление")
        try DataValidation.require(Set(files.keys).isSubset(of: permitted), "Неизвестные файлы в копии")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = try Dictionary(uniqueKeysWithValues: files.keys.compactMap { name -> (String, Data)? in
            guard FileManager.default.fileExists(atPath: url(name).path) else { return nil }
            return (name, try Data(contentsOf: url(name)))
        })
        try JSONEncoder().encode(previous).write(to: url("before-restore.v1.json"), options: .atomic)
        try JSONEncoder().encode(files).write(to: url(journal), options: .atomic)
        do { try apply(files, directory: directory) }
        catch {
            recoveryError = "Восстановление не завершено: \(error.localizedDescription)"
            throw error
        }
    }
    private static func apply(_ files: [String: Data], directory: URL) throws {
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        try DataValidation.require(Set(files.keys).isSubset(of: permitted), "Повреждён журнал восстановления")
        for name in files.keys.sorted() {
            try files[name]!.write(to: url(name), options: .atomic)
        }
        try FileManager.default.removeItem(at: url(journal))
        recoveryError = nil
    }
    static func recoverIfNeeded(directory: URL = LocalFiles.directory) {
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        guard FileManager.default.fileExists(atPath: url(journal).path) else { return }
        do {
            let files = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url(journal)))
            try apply(files, directory: directory)
        } catch {
            recoveryError = "Восстановление не завершено: \(error.localizedDescription). Сохрани файлы приложения перед дальнейшими изменениями."
        }
    }
}
