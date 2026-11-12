import Foundation
import SwiftUI

@MainActor final class FitnessStore: ObservableObject {
    @Published private(set) var catalog: ExerciseCatalog?
    @Published private(set) var program: TrainingProgram?
    @Published private(set) var archivedPrograms: [TrainingProgram] = []
    @Published var completedSets: [SetRecord] = []
    @Published var message: String?

    private let catalogName = "exercises.v1.json"
    private let programName = "program_12w.v1.json"
    private let setsName = "completed_sets.json"

    let directory: URL
    private let bundledDirectory: URL?
    private var storageHealthy = true

    init(directory: URL = LocalFiles.directory, bundledDirectory: URL? = nil) {
        self.directory = directory
        self.bundledDirectory = bundledDirectory
        LocalFiles.recoverIfNeeded(directory: directory)
        reload()
    }

    private func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func content(_ name: String) -> Data? {
        if let data = try? Data(contentsOf: fileURL(name)) { return data }
        if let bundledDirectory { return try? Data(contentsOf: bundledDirectory.appendingPathComponent(name)) }
        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func read<T: Decodable>(_ type: T.Type, file: String) -> T? {
        guard FileManager.default.fileExists(atPath: fileURL(file).path) else { return nil }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: fileURL(file))) }
        catch {
            storageHealthy = false
            message = "Ошибка чтения \(file). Файл сохранён; импорт заблокирован до восстановления: \(error.localizedDescription)"
            return nil
        }
    }

    func loadCatalog() {
        do {
            guard let data = content(catalogName) else { throw ImportError.invalidCatalog }
            let decoded = try JSONDecoder().decode(ExerciseCatalog.self, from: data)
            try DataValidation.catalog(decoded)
            catalog = decoded
        } catch { storageHealthy = false; message = "Каталог не прочитан: \(error.localizedDescription)" }
    }

    func loadProgram() {
        do {
            guard let catalog else { throw ImportError.invalidProgram }
            let local = FileManager.default.fileExists(atPath: fileURL(programName).path) ? try Data(contentsOf: fileURL(programName)) : nil
            let exactURL = bundledDirectory?.appendingPathComponent("program_12w_with_sets.v2.json") ?? Bundle.main.url(forResource: "program_12w_with_sets.v2", withExtension: "json")
            let exact = exactURL.flatMap { try? Data(contentsOf: $0) }
            guard let data = local ?? exact ?? content(programName) else { throw ImportError.invalidProgram }
            var decoded = try JSONDecoder().decode(TrainingProgram.self, from: data)
            if storageHealthy, LocalFiles.recoveryError == nil, local != nil, decoded.schemaVersion == "1.0.0", let exact,
               let legacyURL = bundledDirectory?.appendingPathComponent(programName) ?? Bundle.main.url(forResource: "program_12w.v1", withExtension: "json"),
               let legacyBytes = try? Data(contentsOf: legacyURL),
               let legacy = try? JSONDecoder().decode(TrainingProgram.self, from: legacyBytes) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                // Upgrade only the unchanged original plan, never a user-edited import.
                if try encoder.encode(decoded) == encoder.encode(legacy) {
                    let updated = try JSONDecoder().decode(TrainingProgram.self, from: exact)
                    try DataValidation.program(updated, catalog: catalog)
                    var archive = archivedPrograms
                    archive.append(decoded)
                    try LocalFiles.restore([programName: exact, "program_archive.v1.json": try encoder.encode(archive)], directory: directory)
                    archivedPrograms = archive
                    decoded = updated
                }
            }
            try DataValidation.program(decoded, catalog: catalog)
            program = decoded
        } catch { storageHealthy = false; message = "Программа не прочитана: \(error.localizedDescription)" }
    }

    func importJSON(from url: URL, kind: ImportKind) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try DataValidation.require(storageHealthy && LocalFiles.recoveryError == nil, "Сначала заверши восстановление копии")
            let data = try Data(contentsOf: url)
            switch kind {
            case .catalog:
                let decoded = try JSONDecoder().decode(ExerciseCatalog.self, from: data)
                try DataValidation.catalog(decoded)
                for plan in archivedPrograms + [program].compactMap({ $0 }) {
                    try DataValidation.program(plan, catalog: decoded)
                }
                let ids = Set(decoded.exercises.map(\.id))
                guard decoded.exercises.count == 53,
                      ids.count == 53,
                      decoded.exerciseCount == 53 else {
                    throw ImportError.invalidCatalog
                }
                try data.write(to: fileURL(catalogName), options: .atomic)
                catalog = decoded
                message = "Каталог из 53 упражнений импортирован"
            case .program:
                let decoded = try JSONDecoder().decode(TrainingProgram.self, from: data)
                guard let catalog else { throw ImportError.invalidCatalog }
                try DataValidation.program(decoded, catalog: catalog)
                guard decoded.durationWeeks > 0, !decoded.phases.isEmpty else {
                    throw ImportError.invalidProgram
                }
                var archive = archivedPrograms
                if let current = program {
                    archive.append(current)
                }
                // Retain every revision; past results carry their own movement snapshots.
                try LocalFiles.restore([
                    programName: data,
                    "program_archive.v1.json": try JSONEncoder().encode(archive)
                ], directory: directory)
                archivedPrograms = archive
                program = decoded
                message = "Программа импортирована, предыдущая сохранена в архиве"
            }
        } catch {
            message = "Не удалось импортировать файл: \(error.localizedDescription)"
        }
    }

    func reload() {
        storageHealthy = true
        loadCatalog()
        archivedPrograms = read([TrainingProgram].self, file: "program_archive.v1.json") ?? []
        loadProgram()
        completedSets = read([SetRecord].self, file: setsName) ?? []
    }

    var canExport: Bool { storageHealthy && LocalFiles.recoveryError == nil }

    func exercise(_ id: String) -> Exercise? { catalog?.exercises.first { $0.id == id } }

    /// Conservative default: conditional movements are never treated as approved.
    /// A medical clearance workflow may be added later; until then use the source fallback.
    func resolvedExerciseId(_ id: String) -> String {
        program?.conditionalSubstitutions?[id]?.fallback ?? id
    }

    func substitutionNote(_ id: String) -> String? {
        guard let rule = program?.conditionalSubstitutions?[id] else { return nil }
        return "В плане: \(id). \(rule.reason). Используется разрешённая альтернатива."
    }

    func phase(week: Int) -> ProgramPhase? {
        program?.phases.first { $0.weekStart <= week && week <= $0.weekEnd }
    }

    func weekNumber(for date: Date) -> Int? {
        guard let program, let start = SportDate.from(program.startDate),
              let end = SportDate.from(program.endDate),
              date >= start, date < SportDate.calendar.date(byAdding: .day, value: 1, to: end)! else { return nil }
        let days = SportDate.calendar.dateComponents([.day], from: start, to: date).day ?? 0
        return (days / 7) + 1
    }

    func prescription(_ id: String, on date: Date) -> ExercisePrescription? {
        program?.prescription(id, on: date)
    }

    func nextWorkout(after date: Date = Date()) -> Date? {
        guard let program, let end = SportDate.from(program.endDate) else { return nil }
        var day = SportDate.calendar.startOfDay(for: date)
        while day <= end {
            if workout(on: day) != nil { return day }
            guard let next = SportDate.calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    func workout(on date: Date) -> ProgramDay? { program?.day(on: date) }

    func setCount(exerciseId: String, day: Date) -> Int {
        completedSets.filter { $0.exerciseId == exerciseId && $0.date == SportDate.key(day) }.count
    }

    func markSet(exerciseId: String, day: Date) {
        let previous = completedSets
        completedSets.append(SetRecord(exerciseId: exerciseId, date: SportDate.key(day)))
        if !saveSets() { completedSets = previous }
    }

    func undoSet(exerciseId: String, day: Date) {
        if let idx = completedSets.lastIndex(where: { $0.exerciseId == exerciseId && $0.date == SportDate.key(day) }) {
            let previous = completedSets
            completedSets.remove(at: idx)
            if !saveSets() { completedSets = previous }
        }
    }

    private func saveSets() -> Bool {
        guard canExport else { message = "Сначала восстанови данные из копии"; return false }
        do {
            try JSONEncoder().encode(completedSets).write(to: fileURL(setsName), options: .atomic)
            return true
        } catch { message = error.localizedDescription; return false }
    }

    enum ImportKind { case catalog, program }
    enum ImportError: LocalizedError {
        case invalidCatalog, invalidProgram, unknownExercise
        var errorDescription: String? {
            switch self {
            case .invalidCatalog: return "Требуется каталог ровно из 53 упражнений с уникальными ID"
            case .invalidProgram: return "Ожидается 12-недельный план из 3 этапов"
            case .unknownExercise: return "В программе есть ID, которых нет в загруженном каталоге"
            }
        }
    }
}
