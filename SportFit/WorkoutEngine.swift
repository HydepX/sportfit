import Foundation
import SwiftUI

enum TrainingPhase: String, Codable {
    case prepare, active, rest, paused, summary
}

struct ActualSet: Codable, Identifiable {
    var id: UUID = UUID()
    let reps: Int?
    let weightKg: Double?
    let seconds: Int?
    let completedAt: Date
}

struct WorkoutMovement: Codable, Identifiable {
    let id: UUID
    let sourceId: String
    let exerciseId: String
    let title: String
    let isTimed: Bool
    let target: String
    var sets: [ActualSet] = []
    var skipped: Bool = false
    var skipReason: String? = nil

    init(sourceId: String, exercise: Exercise) {
        id = UUID()
        self.sourceId = sourceId
        exerciseId = exercise.id
        title = exercise.title
        isTimed = exercise.primaryGroup == "Разминка" || exercise.primaryGroup == "Заминка"
            || (exercise.suggestedRepsFromSource ?? "").localizedCaseInsensitiveContains("сек")
            || (exercise.suggestedRepsFromSource ?? "").localizedCaseInsensitiveContains("мин")
        target = exercise.suggestedRepsFromSource ?? "По самочувствию"
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
        self.restSecondsLeft = 45
        self.restAfterLastSet = false
        self.finishedEarly = false
    }

    var completedSetCount: Int { movements.reduce(0) { $0 + $1.sets.count } }
    var skippedCount: Int { movements.filter(\.skipped).count }

    func activeSeconds(now: Date = Date()) -> Int {
        let pause = pauseStartedAt.map { now.timeIntervalSince($0) } ?? 0
        return max(0, Int(now.timeIntervalSince(startedAt) - elapsedPausedSeconds - pause))
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

    var totalSets: Int { movements.reduce(0) { $0 + $1.sets.count } }
    var skippedCount: Int { movements.filter(\.skipped).count }
}

@MainActor
final class WorkoutEngine: ObservableObject {
    @Published private(set) var draft: WorkoutDraft?
    @Published private(set) var history: [WorkoutResult] = []
    @Published var notice: String?

    private let draftFile = "active_workout.v1.json"
    private let historyFile = "workout_history.v1.json"

    init() {
        draft = load(WorkoutDraft.self, file: draftFile)
        history = load([WorkoutResult].self, file: historyFile) ?? []
        // After a process restart, require explicit resume. Preserve any prior pause.
        if var current = draft, current.phase != .summary {
            let now = Date()
            if let previousPause = current.pauseStartedAt {
                current.elapsedPausedSeconds += max(0, now.timeIntervalSince(previousPause))
            }
            current.phase = .paused
            current.restEndsAt = nil
            current.pauseStartedAt = now
            draft = current
            save(current, file: draftFile)
        }
    }

    private func url(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
    }
    private func load<T: Decodable>(_ type: T.Type, file: String) -> T? {
        guard let data = try? Data(contentsOf: url(file)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    @discardableResult
    private func save<T: Encodable>(_ value: T, file: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url(file), options: .atomic)
            return true
        } catch {
            notice = "Не удалось сохранить данные: \(error.localizedDescription)"
            return false
        }
    }
    private func commit(_ update: (inout WorkoutDraft) -> Void) {
        guard var d = draft else { return }
        update(&d)
        draft = d
        save(d, file: draftFile)
    }

    func start(day: ProgramDay, date: Date, store: FitnessStore) {
        guard draft == nil else { notice = "Сначала заверши или удали незавершённую тренировку"; return }
        let movements = day.exerciseIds.compactMap { sourceId -> WorkoutMovement? in
            guard let exercise = store.exercise(store.resolvedExerciseId(sourceId)) else { return nil }
            return WorkoutMovement(sourceId: sourceId, exercise: exercise)
        }
        guard movements.count == day.exerciseIds.count, let programId = store.program?.programId else {
            notice = "Не удалось сопоставить упражнения с библиотекой"
            return
        }
        let d = WorkoutDraft(date: SportDate.key(date), programId: programId,
                             title: day.name, movements: movements)
        draft = d
        save(d, file: draftFile)
    }

    func begin() { commit { $0.phase = .active } }

    func complete(reps: Int?, weight: Double?, seconds: Int?) {
        guard let d = draft, d.phase == .active, d.movements.indices.contains(d.currentIndex) else { return }
        let movement = d.movements[d.currentIndex]
        if movement.isTimed {
            guard let seconds, (1...3600).contains(seconds) else {
                notice = "Укажи длительность от 1 до 3600 секунд"; return
            }
        } else {
            guard let reps, (0...300).contains(reps),
                  let weight, (0...250).contains(weight) else {
                notice = "Проверь повторения (0–300) и вес (0–250 кг)"; return
            }
        }
        commit { d in
            d.movements[d.currentIndex].sets.append(
                ActualSet(reps: reps, weightKg: weight, seconds: seconds, completedAt: Date()))
            // Never assume that one set is the entire prescription.
            // The user chooses whether to add another set or move on.
            d.phase = .rest
            d.restSecondsLeft = 45
            d.restEndsAt = Date().addingTimeInterval(45)
            d.restAfterLastSet = false
        }
    }

    func addAnotherSet() {
        guard draft?.phase == .rest else { return }
        commit {
            $0.phase = .active
            $0.restEndsAt = nil
            $0.restAfterLastSet = false
        }
    }

    func nextExercise() {
        guard let d = draft else { return }
        if d.currentIndex + 1 >= d.movements.count {
            commit { $0.phase = .summary; $0.restEndsAt = nil }
        } else {
            commit {
                $0.currentIndex += 1
                $0.phase = .prepare
                $0.restEndsAt = nil
            }
        }
    }

    func move(by delta: Int) {
        guard let d = draft else { return }
        let target = d.currentIndex + delta
        guard d.movements.indices.contains(target) else { return }
        commit {
            $0.currentIndex = target
            $0.restEndsAt = nil
            $0.phase = .prepare
        }
    }

    func skip(reason: String) {
        guard draft != nil else { return }
        commit {
            $0.movements[$0.currentIndex].skipped = true
            $0.movements[$0.currentIndex].skipReason = reason
        }
        nextExercise()
    }

    func pause() {
        guard let d = draft, d.phase != .paused, d.phase != .summary else { return }
        commit { current in
            if current.phase == .rest {
                current.restSecondsLeft = max(0, Int(ceil(current.restEndsAt?.timeIntervalSinceNow ?? 0)))
            }
            current.restEndsAt = nil
            current.pauseStartedAt = Date()
            current.phase = .paused
        }
    }
    func resume() {
        guard let d = draft, d.phase == .paused else { return }
        commit { current in
            current.elapsedPausedSeconds += Date().timeIntervalSince(current.pauseStartedAt ?? Date())
            current.pauseStartedAt = nil
            current.phase = .active
        }
    }

    func extendRest(_ seconds: Int) {
        guard seconds > 0, draft?.phase == .rest else { return }
        commit {
            $0.restEndsAt = ($0.restEndsAt ?? Date()).addingTimeInterval(TimeInterval(seconds))
            $0.restSecondsLeft += seconds
        }
    }
    func tick() {
        guard let d = draft, d.phase == .rest,
              let end = d.restEndsAt, end <= Date() else { return }
        commit {
            $0.phase = .active
            $0.restEndsAt = nil
        }
    }
    func restRemaining() -> Int {
        guard let d = draft, d.phase == .rest, let end = d.restEndsAt else { return 0 }
        return max(0, Int(ceil(end.timeIntervalSinceNow)))
    }
    func earlyFinish() {
        commit {
            $0.finishedEarly = true
            $0.phase = .summary
            $0.restEndsAt = nil
        }
    }

    @discardableResult
    func finish(feeling: String?) -> WorkoutResult? {
        guard let d = draft, d.phase == .summary else { return nil }
        let result = WorkoutResult(
            id: d.id, date: d.date, programId: d.programId, title: d.title,
            startedAt: d.startedAt, finishedAt: Date(),
            durationSeconds: d.activeSeconds(), feeling: feeling,
            finishedEarly: d.finishedEarly, movements: d.movements)
        // Idempotency: if a saved workout is re-opened, keep one result per UUID.
        if !history.contains(where: { $0.id == result.id }) {
            history.append(result)
            guard save(history, file: historyFile) else {
                history.removeAll { $0.id == result.id }
                return nil
            }
        }
        draft = nil
        try? FileManager.default.removeItem(at: url(draftFile))
        return result
    }
    func discard() {
        draft = nil
        try? FileManager.default.removeItem(at: url(draftFile))
    }
}
