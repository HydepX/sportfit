import Foundation

enum RunDayOutcome: String, Codable {
    case completed, partial, skipped, rest
    var title: String {
        switch self {
        case .completed: return "Выполнено"
        case .partial: return "Частично выполнено"
        case .skipped: return "Пропущено"
        case .rest: return "Отдых завершён"
        }
    }
}

struct RunDayClosure: Codable {
    let dayIndex: Int
    let outcome: RunDayOutcome
    let closedAt: Date
}

/// A run owns an immutable program snapshot. Template dates only identify source
/// prescriptions; the user's progress is an ordered sequence, never a deadline.
struct ProgramRun: Codable, Identifiable {
    let id: UUID
    let title: String
    let program: TrainingProgram
    let startedAt: Date
    var closedAt: Date?
    var days: [RunDayClosure]
    var extraRests: [Date]
    var retiredAt: Date? = nil
    var isRetired: Bool { retiredAt != nil }

    init(title: String, program: TrainingProgram) {
        id = UUID()
        self.title = title
        self.program = program
        startedAt = Date()
        days = []
        extraRests = []
    }

    var dayCount: Int { (1...53).contains(program.durationWeeks) ? program.durationWeeks * 7 : 0 }
    var currentDay: Int? { (0..<dayCount).first { index in !days.contains { $0.dayIndex == index } } }
    var completedDayCount: Int { days.count }
    var workoutCount: Int { (0..<dayCount).filter { workout(on: $0) != nil }.count }
    var completedWorkoutCount: Int { days.filter { $0.outcome == .completed }.count }

    func sourceDate(for index: Int) -> Date? {
        guard (0..<dayCount).contains(index), let start = SportDate.from(program.startDate) else { return nil }
        return SportDate.calendar.date(byAdding: .day, value: index, to: start)
    }
    func workout(on index: Int) -> ProgramDay? { sourceDate(for: index).flatMap { program.day(on: $0) } }
    func results(on index: Int, history: [WorkoutResult]) -> [WorkoutResult] {
        history.filter { $0.runId == id && $0.runDayIndex == index }.sorted { $0.finishedAt > $1.finishedAt }
    }
    func outcome(on index: Int, history: [WorkoutResult]) -> RunDayOutcome? {
        if let closure = days.first(where: { $0.dayIndex == index }) { return closure.outcome }
        let results = results(on: index, history: history)
        if results.contains(where: \.isComplete) { return .completed }
        return results.isEmpty ? nil : .partial
    }

    mutating func closeDay(history: [WorkoutResult], allowIncomplete: Bool, now: Date = Date()) throws {
        try DataValidation.require(closedAt == nil && !isRetired, "Уровень закрыт или программа заменена")
        guard let index = currentDay else { throw DataValidation.Failure(message: "Все дни уже закрыты") }
        let outcome: RunDayOutcome
        if workout(on: index) == nil { outcome = .rest }
        else { outcome = self.outcome(on: index, history: history) ?? .skipped }
        try DataValidation.require(outcome == .completed || outcome == .rest || allowIncomplete,
                                   "Подтверди закрытие дня с неполным результатом или пропуском")
        days.append(RunDayClosure(dayIndex: index, outcome: outcome, closedAt: now))
    }

    mutating func close(allowIncomplete: Bool, now: Date = Date()) throws {
        try DataValidation.require(closedAt == nil && !isRetired, "Уровень закрыт или программа заменена")
        try DataValidation.require(allowIncomplete || (days.count == dayCount &&
            days.allSatisfy { $0.outcome == .completed || $0.outcome == .rest }),
            "Подтверди закрытие уровня с незавершёнными днями")
        closedAt = now
    }

    func validate(catalog: ExerciseCatalog) throws {
        try DataValidation.program(program, catalog: catalog)
        try validateStructure()
    }

    func validateStructure() throws {
        try DataValidation.require(dayCount > 0 && !program.programId.isEmpty && SportDate.from(program.startDate) != nil,
                                   "Некорректная программа уровня")
        try DataValidation.require(!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 100,
                                   "Некорректное название уровня")
        // Closures must form a prefix: a future day cannot unlock itself.
        try DataValidation.require(days.map(\.dayIndex) == Array(0..<days.count) && days.count <= dayCount,
                                   "Некорректный порядок закрытых дней")
        for day in days {
            try DataValidation.require((workout(on: day.dayIndex) == nil) == (day.outcome == .rest),
                                       "Статус дня не соответствует программе")
        }
        try DataValidation.require(closedAt.map { $0 >= startedAt } ?? true, "Некорректное завершение уровня")
    }

    static func validate(_ runs: [ProgramRun], catalog: ExerciseCatalog) throws {
        try DataValidation.require(Set(runs.map(\.id)).count == runs.count && runs.filter { $0.closedAt == nil && !$0.isRetired }.count <= 1,
                                   "Повторяющиеся или несколько активных уровней")
        for run in runs { try run.validate(catalog: catalog) }
    }
}

extension TrainingProgram {
    func prescription(_ id: String, on date: Date, position: Int? = nil) -> ExercisePrescription? {
        if let sessions {
            guard let session = sessions.first(where: { $0.date == SportDate.key(date) }) else { return nil }
            if let position, session.items.indices.contains(position), session.items[position].exerciseId == id {
                return session.items[position].prescription
            }
            return session.items.first { $0.exerciseId == id }?.prescription
        }
        if let start = SportDate.from(startDate) {
            let offset = SportDate.calendar.dateComponents([.day], from: start, to: date).day ?? -1
            if offset >= 0, let rule = phases.first(where: { $0.weekStart <= offset / 7 + 1 && offset / 7 + 1 <= $0.weekEnd })?.prescriptions?[id] {
                return rule
            }
        }
        return prescriptions?[id]
    }
}
