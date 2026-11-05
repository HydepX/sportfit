import Foundation
import SwiftUI

@MainActor final class FitnessStore: ObservableObject {
    @Published private(set) var catalog: ExerciseCatalog?
    @Published private(set) var program: TrainingProgram?
    @Published var completedSets: [SetRecord] = []
    @Published var message: String?

    private let catalogName = "exercises.v1.json"
    private let programName = "program_12w.v1.json"
    private let setsName = "completed_sets.json"

    init() {
        loadCatalog()
        loadProgram()
        if let data = try? Data(contentsOf: fileURL(setsName)),
           let records = try? JSONDecoder().decode([SetRecord].self, from: data) {
            completedSets = records
        }
    }

    private func fileURL(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
    }

    private func content(_ name: String) -> Data? {
        if let data = try? Data(contentsOf: fileURL(name)) { return data }
        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { return nil }
        return try? Data(contentsOf: url)
    }

    func loadCatalog() {
        guard let data = content(catalogName),
              let decoded = try? JSONDecoder().decode(ExerciseCatalog.self, from: data) else { return }
        catalog = decoded
    }

    func loadProgram() {
        guard let data = content(programName),
              let decoded = try? JSONDecoder().decode(TrainingProgram.self, from: data) else { return }
        program = decoded
    }

    func importJSON(from url: URL, kind: ImportKind) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            switch kind {
            case .catalog:
                let decoded = try JSONDecoder().decode(ExerciseCatalog.self, from: data)
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
                guard decoded.durationWeeks == 12, decoded.phases.count == 3 else {
                    throw ImportError.invalidProgram
                }
                let referenced = Set(decoded.phases.flatMap(\.days).flatMap(\.exerciseIds))
                if let catalog {
                    let known = Set(catalog.exercises.map(\.id))
                    guard referenced.isSubset(of: known) else { throw ImportError.unknownExercise }
                }
                try data.write(to: fileURL(programName), options: .atomic)
                program = decoded
                message = "Программа на 12 недель импортирована"
            }
        } catch {
            message = "Не удалось импортировать файл: \(error.localizedDescription)"
        }
    }

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
              date >= start, date < Calendar.current.date(byAdding: .day, value: 1, to: end)! else { return nil }
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: date).day ?? 0
        return (days / 7) + 1
    }

    func workout(on date: Date) -> ProgramDay? {
        guard let week = weekNumber(for: date), let phase = phase(week: week) else { return nil }
        let day = Calendar.current.component(.weekday, from: date)
        let key = [1: "Вс", 2: "Пн", 3: "Вт", 4: "Ср", 5: "Чт", 6: "Пт", 7: "Сб"][day]
        return phase.days.first { $0.dayOfWeek == key }
    }

    func setCount(exerciseId: String, day: Date) -> Int {
        completedSets.filter { $0.exerciseId == exerciseId && $0.date == SportDate.key(day) }.count
    }

    func markSet(exerciseId: String, day: Date) {
        completedSets.append(SetRecord(exerciseId: exerciseId, date: SportDate.key(day)))
        saveSets()
    }

    func undoSet(exerciseId: String, day: Date) {
        if let idx = completedSets.lastIndex(where: { $0.exerciseId == exerciseId && $0.date == SportDate.key(day) }) {
            completedSets.remove(at: idx)
            saveSets()
        }
    }

    private func saveSets() {
        guard let data = try? JSONEncoder().encode(completedSets) else { return }
        try? data.write(to: fileURL(setsName), options: .atomic)
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
