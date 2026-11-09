import Foundation

struct DetailedSession: Codable {
    let sessionId: String
    let week: Int
    let date: String
    let day: String
    let name: String
    let phaseId: String
    let items: [DetailedExercise]
    enum CodingKeys: String, CodingKey {
        case week, date, day, name, items
        case sessionId = "session_id"
        case phaseId = "phase_id"
    }
}

struct DetailedExercise: Codable {
    let order: Int
    let exerciseId: String
    let name: String
    let stage: String
    let mode: String
    let sets: Int
    let targetReps: Int?
    let targetSeconds: Int?
    let restSeconds: Int
    let unit: String?
    let load: String?
    let requiresClearance: Bool?
    let clearanceNote: String?
    let notes: String?
    let originalHint: String?
    enum CodingKeys: String, CodingKey {
        case order, name, stage, mode, sets, unit, load, notes
        case exerciseId = "exercise_id"
        case targetReps = "target_reps"
        case targetSeconds = "target_seconds"
        case restSeconds = "rest_seconds"
        case requiresClearance = "requires_clearance"
        case clearanceNote = "clearance_note"
        case originalHint = "original_hint"
    }
    var prescription: ExercisePrescription {
        ExercisePrescription(sets: sets, repetitions: targetDescription, restSeconds: restSeconds,
            progression: notes, mode: mode, targetReps: targetReps, targetSeconds: targetSeconds,
            unit: unit, load: load, requiresClearance: requiresClearance, clearanceNote: clearanceNote)
    }
    var targetDescription: String {
        if mode == "duration" { return "\(targetSeconds ?? 0) сек" }
        let suffix = mode == "repetitions_per_side" ? "на каждую сторону" : mode == "breath_cycles" ? "дыхательных циклов" : "повторений"
        return "\(targetReps ?? 0) \(suffix)"
    }
}
