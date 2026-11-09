import Foundation

struct ExercisePrescription: Codable {
    let sets: Int?
    let repetitions: String?
    let restSeconds: Int?
    let progression: String?
    var mode: String? = nil
    var targetReps: Int? = nil
    var targetSeconds: Int? = nil
    var unit: String? = nil
    var load: String? = nil
    var requiresClearance: Bool? = nil
    var clearanceNote: String? = nil
}

enum DataValidation {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func catalog(_ catalog: ExerciseCatalog) throws {
        let ids = catalog.exercises.map(\.id)
        try require(catalog.schemaVersion == "1.0.0", "Неподдерживаемая версия каталога")
        try require(catalog.exerciseCount == 53 && ids.count == 53 && Set(ids).count == 53,
                    "Нужны 53 уникальных упражнения")
        try require(catalog.exercises.allSatisfy { !$0.id.isEmpty && !$0.title.isEmpty && !$0.instructions.isEmpty },
                    "Неполное описание упражнения")
    }
    static func program(_ program: TrainingProgram, catalog: ExerciseCatalog) throws {
        try self.catalog(catalog)
        try require(["1.0.0", "2.0.0"].contains(program.schemaVersion) && !program.programId.isEmpty,
                    "Неподдерживаемая версия программы")
        guard let start = SportDate.from(program.startDate), let end = SportDate.from(program.endDate) else {
            throw Failure(message: "Некорректные даты программы")
        }
        let days = SportDate.calendar.dateComponents([.day], from: start, to: end).day ?? -1
        try require(program.durationWeeks > 0 && program.durationWeeks <= 53 && days == program.durationWeeks * 7 - 1,
                    "Даты не соответствуют длительности программы")
        let known = Set(catalog.exercises.map(\.id))
        if program.schemaVersion == "2.0.0" {
            guard let sessions = program.sessions, !sessions.isEmpty, program.sessionCount == sessions.count else {
                throw Failure(message: "Отсутствуют отдельные занятия v2")
            }
            try require(program.exerciseCount == catalog.exerciseCount, "Количество упражнений v2 не совпадает с каталогом")
            try require(Set(sessions.map(\.date)).count == sessions.count && Set(sessions.map(\.sessionId)).count == sessions.count,
                        "Повторяющиеся даты или ID занятий")
            for session in sessions {
                guard let date = SportDate.from(session.date) else { throw Failure(message: "Некорректная дата занятия") }
                let offset = SportDate.calendar.dateComponents([.day], from: start, to: date).day ?? -1
                let weekday = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"][SportDate.calendar.component(.weekday, from: date) - 1]
                try require(date >= start && date <= end && session.week == offset / 7 + 1 && session.day == weekday,
                            "Дата занятия не соответствует неделе или дню")
                try require(!session.items.isEmpty && session.items.map(\.order) == Array(1...session.items.count) &&
                            Set(session.items.map(\.exerciseId)).count == session.items.count, "Нарушен порядок или повторяются упражнения")
                try require(program.phases.contains { $0.phaseId == session.phaseId && $0.weekStart <= session.week && session.week <= $0.weekEnd }, "Занятие не соответствует этапу")
                for item in session.items {
                    try require(known.contains(item.exerciseId) && (1...100).contains(item.sets) && (0...3600).contains(item.restSeconds), "Некорректные подходы или отдых")
                    try require(["warmup", "main", "cooldown"].contains(item.stage), "Неизвестный этап упражнения")
                    if item.requiresClearance == true {
                        try require(program.conditionalSubstitutions?[item.exerciseId] == nil, "Для этого упражнения в v2 требуется разрешение или пропуск без замены")
                    }
                    if item.mode == "duration" {
                        try require(item.targetSeconds.map { (1...3600).contains($0) } == true && item.targetReps == nil, "Некорректное время упражнения")
                    } else {
                        try require(["repetitions", "repetitions_per_side", "breath_cycles"].contains(item.mode) &&
                                    item.targetReps.map { (1...300).contains($0) } == true && item.targetSeconds == nil, "Некорректные повторы")
                    }
                }
            }
        }

        var weeks = Set<Int>()
        let weekdays: Set<String> = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
        try require(!program.phases.isEmpty && Set(program.phases.map(\.phaseId)).count == program.phases.count,
                    "Этапы должны иметь уникальные ID")
        for phase in program.phases {
            try require(phase.weekStart >= 1 && phase.weekEnd >= phase.weekStart && phase.weekEnd <= program.durationWeeks,
                        "Некорректные границы этапа")
            for week in phase.weekStart...phase.weekEnd {
                try require(weeks.insert(week).inserted, "Этапы пересекаются")
            }
            try require(!phase.days.isEmpty && Set(phase.days.map(\.dayOfWeek)).count == phase.days.count,
                        "Дни этапа должны быть уникальными")
            for day in phase.days {
                try require(weekdays.contains(day.dayOfWeek) && !day.exerciseIds.isEmpty &&
                            Set(day.exerciseIds).isSubset(of: known), "Неизвестный день или упражнение")
            }
        }
        try require(weeks.count == program.durationWeeks, "Программа содержит пробелы между этапами")
        for (source, rule) in program.conditionalSubstitutions ?? [:] {
            try require(known.contains(source) && known.contains(rule.fallback) && source != rule.fallback,
                        "Некорректная замена упражнения")
            try require(program.conditionalSubstitutions?[rule.fallback] == nil, "Цепочки замен не поддерживаются")
        }
        for rules in [program.prescriptions ?? [:]] + program.phases.map({ $0.prescriptions ?? [:] }) {
            for (id, rule) in rules {
                try require(known.contains(id) && (rule.sets.map { (1...100).contains($0) } ?? true) &&
                            (rule.restSeconds.map { (0...3600).contains($0) } ?? true), "Некорректное назначение")
            }
        }
    }
}
