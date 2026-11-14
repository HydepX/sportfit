import Foundation

struct ExerciseCatalog: Codable {
    let schemaVersion: String
    let exerciseCount: Int
    let exercises: [Exercise]

    var currentExercises: [Exercise] { exercises.filter { $0.retired != true } }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exerciseCount = "exercise_count"
        case exercises
    }
}

struct Exercise: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let primaryGroup: String
    let equipment: [String]
    let description: String
    let instructions: [String]
    let commonMistakesDraft: [String]?
    let commonMistakesReviewStatus: String?
    let safetyFlag: String
    let safetyNote: String?
    let originalExternalReference: String?
    let suggestedRepsFromSource: String?
    let suggestedRestFromSource: String?
    let media: ExerciseMedia?
    var retired: Bool? = nil
    var metricType: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, equipment, description, instructions, media, retired
        case metricType = "metric_type"
        case primaryGroup = "primary_group"
        case commonMistakesDraft = "common_mistakes_draft"
        case commonMistakesReviewStatus = "common_mistakes_review_status"
        case safetyFlag = "safety_flag"
        case safetyNote = "safety_note"
        case originalExternalReference = "original_external_reference"
        case suggestedRepsFromSource = "suggested_reps_from_source"
        case suggestedRestFromSource = "suggested_rest_from_source"
    }

    static func == (lhs: Exercise, rhs: Exercise) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ExerciseMedia: Codable {
    let status: String
    let animation: MediaAnimation?
    var photo: ExercisePhoto? = nil
}
struct ExercisePhoto: Codable {
    let asset: String
    let columns: Int
    let rows: Int
    let index: Int
}
struct MediaAnimation: Codable {
    let path: String?
    let status: String?
}

struct TrainingProgram: Codable {
    let schemaVersion: String
    let programId: String
    let startDate: String
    let endDate: String
    let durationWeeks: Int
    let phases: [ProgramPhase]
    let sessions: [DetailedSession]?
    let generalRules: [String: String]?
    let sessionCount: Int?
    let exerciseCount: Int?
    let programDescription: String?
    let derivedFrom: String?
    let prescriptions: [String: ExercisePrescription]?
    let conditionalSubstitutions: [String: ConditionalSubstitution]?

    enum CodingKeys: String, CodingKey {
        case phases, prescriptions, sessions
        case generalRules = "general_rules"
        case sessionCount = "session_count"
        case exerciseCount = "exercise_count"
        case programDescription = "description"
        case derivedFrom = "derived_from"
        case schemaVersion = "schema_version"
        case programId = "program_id"
        case startDate = "start_date"
        case endDate = "end_date"
        case durationWeeks = "duration_weeks"
        case conditionalSubstitutions = "conditional_substitutions"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(String.self, forKey: .schemaVersion)
        programId = try c.decode(String.self, forKey: .programId)
        startDate = try c.decode(String.self, forKey: .startDate)
        endDate = try c.decode(String.self, forKey: .endDate)
        durationWeeks = try c.decode(Int.self, forKey: .durationWeeks)
        prescriptions = try c.decodeIfPresent([String: ExercisePrescription].self, forKey: .prescriptions)
        conditionalSubstitutions = try c.decodeIfPresent([String: ConditionalSubstitution].self, forKey: .conditionalSubstitutions)
        sessions = try c.decodeIfPresent([DetailedSession].self, forKey: .sessions)
        generalRules = try c.decodeIfPresent([String: String].self, forKey: .generalRules)
        sessionCount = try c.decodeIfPresent(Int.self, forKey: .sessionCount)
        exerciseCount = try c.decodeIfPresent(Int.self, forKey: .exerciseCount)
        programDescription = try c.decodeIfPresent(String.self, forKey: .programDescription)
        derivedFrom = try c.decodeIfPresent(String.self, forKey: .derivedFrom)
        if let existing = try c.decodeIfPresent([ProgramPhase].self, forKey: .phases) { phases = existing }
        else {
            let grouped = Dictionary(grouping: sessions ?? [], by: \.phaseId)
            phases = grouped.keys.sorted().map { id in
                let days = (grouped[id] ?? []).sorted { $0.date < $1.date }
                var seen = Set<String>()
                let firstWeek = days.map(\.week).min() ?? 1
                let lastWeek = days.map(\.week).max() ?? 1
                return ProgramPhase(phaseId: id, weekStart: firstWeek,
                    weekEnd: lastWeek, title: "Недели \(firstWeek)–\(lastWeek)", subtitle: "Точные назначения из программы",
                    days: days.filter { seen.insert($0.day).inserted }.map {
                        ProgramDay(dayOfWeek: $0.day, name: $0.name, exerciseIds: $0.items.map(\.exerciseId))
                    }, prescriptions: nil)
            }
        }
    }

}

struct ProgramPhase: Codable, Identifiable {
    let phaseId: String
    let weekStart: Int
    let weekEnd: Int
    let title: String
    let subtitle: String
    let days: [ProgramDay]
    let prescriptions: [String: ExercisePrescription]?
    var id: String { phaseId }

    enum CodingKeys: String, CodingKey {
        case phaseId = "phase_id"
        case weekStart = "week_start"
        case weekEnd = "week_end"
        case title, subtitle, days, prescriptions
    }
}

struct ProgramDay: Codable {
    let dayOfWeek: String
    let name: String
    let exerciseIds: [String]

    enum CodingKeys: String, CodingKey {
        case dayOfWeek = "day_of_week"
        case name
        case exerciseIds = "exercise_ids"
    }
}

struct ConditionalSubstitution: Codable {
    let fallback: String
    let reason: String
}

struct SetRecord: Codable, Identifiable {
    let id: UUID
    let exerciseId: String
    let date: String
    let completedAt: Date
    init(exerciseId: String, date: String) {
        self.id = UUID()
        self.exerciseId = exerciseId
        self.date = date
        self.completedAt = Date()
    }
}

enum SportDate {
    static var iso: DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        value.firstWeekday = 2
        return value
    }
    static func from(_ text: String) -> Date? {
        guard let date = iso.date(from: text), iso.string(from: date) == text else { return nil }
        return date
    }
    static func key(_ date: Date) -> String { iso.string(from: date) }
    static func dayNumber(_ date: Date) -> Int { Calendar.current.component(.day, from: date) }
}

extension TrainingProgram {
    func day(on date: Date) -> ProgramDay? {
        guard let start = SportDate.from(startDate), let end = SportDate.from(endDate) else { return nil }
        let value = SportDate.calendar.startOfDay(for: date)
        if let sessions {
            guard let session = sessions.first(where: { $0.date == SportDate.key(date) }) else { return nil }
            return ProgramDay(dayOfWeek: session.day, name: session.name, exerciseIds: session.items.map(\.exerciseId))
        }
        guard value >= start && value <= end else { return nil }
        let offset = SportDate.calendar.dateComponents([.day], from: start, to: value).day ?? -1
        let week = offset / 7 + 1
        let weekdays = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"]
        let weekday = weekdays[SportDate.calendar.component(.weekday, from: value) - 1]
        return phases.first { $0.weekStart <= week && week <= $0.weekEnd }?.days.first { $0.dayOfWeek == weekday }
    }
}
