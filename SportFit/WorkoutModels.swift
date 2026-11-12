import Foundation

enum TrainingPhase: String, Codable {
    case prepare, active, rest, paused, summary
}

struct ActualSet: Codable, Identifiable {
    var id: UUID = UUID()
    var reps: Int?
    var weightKg: Double?
    var seconds: Int?
    let completedAt: Date
}

struct WorkoutMovement: Codable, Identifiable {
    let id: UUID
    let sourceId: String
    let exerciseId: String
    let title: String
    let isTimed: Bool
    let target: String
    var prescription: ExercisePrescription?
    var sourceRestSeconds: Int?
    var clearanceConfirmed: Bool?
    var sets: [ActualSet] = []
    var skipped: Bool = false
    var skipReason: String? = nil

    init(sourceId: String, exercise: Exercise, prescription: ExercisePrescription? = nil) {
        id = UUID()
        self.sourceId = sourceId
        exerciseId = exercise.id
        title = exercise.title
        let requestedTarget = prescription?.repetitions ?? exercise.suggestedRepsFromSource ?? "Не задано в программе"
        isTimed = prescription?.mode.map { $0 == "duration" } ?? (requestedTarget.localizedCaseInsensitiveContains("сек") || requestedTarget.localizedCaseInsensitiveContains("мин"))
        self.prescription = prescription
        sourceRestSeconds = exercise.suggestedRestFromSource.flatMap { text in
            let number = text.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
            return number.map { text.contains("мин") ? $0 * 60 : $0 }
        }
        target = requestedTarget
    }
}

struct WorkoutDraft: Codable, Identifiable {
    let id: UUID
    let date: String
    let programId: String
    let title: String
    let startedAt: Date
    var currentIndex: Int
    var phase: TrainingPhase
    var movements: [WorkoutMovement]
    var elapsedPausedSeconds: TimeInterval
    var pauseStartedAt: Date?
    var restEndsAt: Date?
    var restSecondsLeft: Int
    var restAfterLastSet: Bool
    var finishedEarly: Bool
    var pausedPhase: TrainingPhase?
    var endedAt: Date?
    var runId: UUID?
    var runDayIndex: Int?

    init(date: String, programId: String, title: String, movements: [WorkoutMovement]) {
        id = UUID()
        self.date = date
        self.programId = programId
        self.title = title
        self.startedAt = Date()
        self.currentIndex = 0
        self.phase = .prepare
        self.movements = movements
        self.elapsedPausedSeconds = 0
        self.pauseStartedAt = nil
        self.restEndsAt = nil
        self.restSecondsLeft = 0
        self.restAfterLastSet = false
        self.finishedEarly = false
    }

    var completedSetCount: Int { movements.reduce(0) { $0 + $1.sets.count } }
    var skippedCount: Int { movements.filter(\.skipped).count }

    func activeSeconds(now: Date = Date()) -> Int {
        let pause = pauseStartedAt.map { now.timeIntervalSince($0) } ?? 0
        return max(0, Int((endedAt ?? now).timeIntervalSince(startedAt) - elapsedPausedSeconds - pause))
    }
}

struct WorkoutResult: Codable, Identifiable {
    let id: UUID
    let date: String
    let programId: String
    let title: String
    let startedAt: Date
    let finishedAt: Date
    let durationSeconds: Int
    let feeling: String?
    let finishedEarly: Bool
    let movements: [WorkoutMovement]
    var runId: UUID? = nil
    var runDayIndex: Int? = nil

    var isComplete: Bool {
        !finishedEarly && !movements.isEmpty && movements.allSatisfy {
            !$0.skipped && $0.sets.count >= ($0.prescription?.sets ?? 1)
        }
    }
    var completionLabel: String {
        if finishedEarly { return "Завершено досрочно" }
        return isComplete ? "Все упражнения отмечены" : "Частично выполнено"
    }
    var totalSets: Int { movements.reduce(0) { $0 + $1.sets.count } }
    var skippedCount: Int { movements.filter(\.skipped).count }
}

