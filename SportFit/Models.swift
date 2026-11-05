import Foundation

struct ExerciseCatalog: Codable {
    let schemaVersion: String
    let exerciseCount: Int
    let exercises: [Exercise]

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

    enum CodingKeys: String, CodingKey {
        case id, title, equipment, description, instructions, media
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
    let conditionalSubstitutions: [String: ConditionalSubstitution]?

    enum CodingKeys: String, CodingKey {
        case phases
        case schemaVersion = "schema_version"
        case programId = "program_id"
        case startDate = "start_date"
        case endDate = "end_date"
        case durationWeeks = "duration_weeks"
        case conditionalSubstitutions = "conditional_substitutions"
    }
}

struct ProgramPhase: Codable, Identifiable {
    let phaseId: String
    let weekStart: Int
    let weekEnd: Int
    let title: String
    let subtitle: String
    let days: [ProgramDay]
    var id: String { phaseId }

    enum CodingKeys: String, CodingKey {
        case phaseId = "phase_id"
        case weekStart = "week_start"
        case weekEnd = "week_end"
        case title, subtitle, days
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
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func from(_ text: String) -> Date? { iso.date(from: text) }
    static func key(_ date: Date) -> String { iso.string(from: date) }
    static func dayNumber(_ date: Date) -> Int { Calendar.current.component(.day, from: date) }
}
