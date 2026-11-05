import Foundation
import SwiftUI

@MainActor
final class WorkoutEngine: ObservableObject {
    @Published private(set) var draft: WorkoutDraft?
    @Published private(set) var history: [WorkoutResult] = []
    @Published var notice: String?

    private let draftFile = "active_workout.v1.json"
    private let historyFile = "workout_history.v1.json"

    private let directory: URL
    private var storageHealthy = true
    var canExport: Bool { storageHealthy && LocalFiles.recoveryError == nil }

    init(directory: URL = LocalFiles.directory) {
        self.directory = directory
        LocalFiles.recoverIfNeeded()
        draft = load(WorkoutDraft?.self, file: draftFile) ?? nil
        history = load([WorkoutResult].self, file: historyFile) ?? []
        // Absolute rest deadlines continue across screen lock and process restart.
        // A pre-existing pause remains paused; never silently discard the rest state.
        if let id = draft?.id, history.contains(where: { $0.id == id }) {
            draft = nil
            try? FileManager.default.removeItem(at: url(draftFile))
        }
        if let current = draft, !current.movements.indices.contains(current.currentIndex) {
            storageHealthy = false
            notice = "Повреждён индекс черновика; восстанови резервную копию"
        }
        tick()
    }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }
    private func load<T: Decodable>(_ type: T.Type, file: String) -> T? {
        guard FileManager.default.fileExists(atPath: url(file).path) else { return nil }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url(file))) }
        catch {
            storageHealthy = false
            notice = "Не удалось прочитать \(file). Исходный файл сохранён; новые записи заблокированы: \(error.localizedDescription)"
            return nil
        }
    }
    @discardableResult
    private func save<T: Encodable>(_ value: T, file: String) -> Bool {
        guard storageHealthy, LocalFiles.recoveryError == nil else {
            notice = LocalFiles.recoveryError ?? "Сначала восстанови повреждённые данные из копии"
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url(file), options: .atomic)
            return true
        } catch {
            notice = "Не удалось сохранить данные: \(error.localizedDescription)"
            return false
        }
    }
    @discardableResult
    private func commit(_ update: (inout WorkoutDraft) -> Void) -> Bool {
        guard var d = draft else { return false }
        update(&d)
        guard save(d, file: draftFile) else { return false }
        draft = d
        return true
    }

    func start(day: ProgramDay, date: Date, store: FitnessStore) {
        guard draft == nil else { notice = "Сначала заверши или удали незавершённую тренировку"; return }
        guard !history.contains(where: { $0.programId == store.program?.programId && $0.date == SportDate.key(date) }) else {
            notice = "За этот день уже есть результат. Открой его в журнале"; return
        }
        let movements = day.exerciseIds.compactMap { sourceId -> WorkoutMovement? in
            guard let exercise = store.exercise(store.resolvedExerciseId(sourceId)) else { return nil }
            return WorkoutMovement(sourceId: sourceId, exercise: exercise, prescription: store.program?.prescriptions?[sourceId])
        }
        guard !movements.isEmpty, movements.count == day.exerciseIds.count, let programId = store.program?.programId else {
            notice = "Не удалось сопоставить упражнения с библиотекой"
            return
        }
        let d = WorkoutDraft(date: SportDate.key(date), programId: programId,
                             title: day.name, movements: movements)
        if save(d, file: draftFile) { draft = d }
    }

    func begin() {
        guard draft?.phase == .prepare else { return }
        commit { $0.phase = .active }
    }

    func complete(reps: Int?, weight: Double?, seconds: Int?) {
        guard let d = draft, d.phase == .active, d.movements.indices.contains(d.currentIndex) else { return }
        let movement = d.movements[d.currentIndex]
        if movement.isTimed {
            guard let seconds, (1...3600).contains(seconds) else {
                notice = "Укажи длительность от 1 до 3600 секунд"; return
            }
        } else {
            guard let reps, (1...300).contains(reps),
                  let weight, (0...250).contains(weight) else {
                notice = "Проверь повторения (0–300) и вес (0–250 кг)"; return
            }
        }
        commit { d in
            d.movements[d.currentIndex].sets.append(
                ActualSet(reps: reps, weightKg: weight, seconds: seconds, completedAt: Date()))
            // Never assume that one set is the entire prescription.
            // The user chooses whether to add another set or move on.
            d.movements[d.currentIndex].skipped = false
            d.movements[d.currentIndex].skipReason = nil
            let rest = movement.prescription?.restSeconds ?? movement.sourceRestSeconds
            // Missing prescriptions are explicit; never invent the same rest for every exercise.
            d.restSecondsLeft = rest ?? 0
            d.phase = (rest ?? 0) > 0 ? .rest : .active
            d.restEndsAt = rest.flatMap { $0 > 0 ? Date().addingTimeInterval(Double($0)) : nil }
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
        guard let d = draft, d.phase != .paused, d.phase != .summary else { return }
        if d.currentIndex + 1 >= d.movements.count {
            commit { $0.phase = .summary; $0.endedAt = Date(); $0.restEndsAt = nil }
        } else {
            commit {
                $0.currentIndex += 1
                $0.phase = .prepare
                $0.restEndsAt = nil
            }
        }
    }

    func move(by delta: Int) {
        guard let d = draft, d.phase != .summary, d.phase != .paused else { return }
        let target = d.currentIndex + delta
        guard d.movements.indices.contains(target) else { return }
        commit {
            $0.currentIndex = target
            $0.restEndsAt = nil
            $0.phase = .prepare
        }
    }

    func skip(reason: String) {
        guard let d = draft, d.phase != .summary, d.phase != .paused, d.movements.indices.contains(d.currentIndex) else { return }
        if commit({
            $0.movements[$0.currentIndex].skipped = true
            $0.movements[$0.currentIndex].skipReason = reason
        }) { nextExercise() }
    }

    func pause() {
        guard let d = draft, d.phase != .paused, d.phase != .summary else { return }
        commit { current in
            if current.phase == .rest {
                current.restSecondsLeft = max(0, Int(ceil(current.restEndsAt?.timeIntervalSinceNow ?? 0)))
            }
            current.pausedPhase = current.phase
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
            current.phase = current.pausedPhase ?? .active
            if current.phase == .rest {
                current.restEndsAt = Date().addingTimeInterval(Double(current.restSecondsLeft))
            }
            current.pausedPhase = nil
        }
        tick()
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
            if let paused = $0.pauseStartedAt {
                $0.elapsedPausedSeconds += Date().timeIntervalSince(paused)
                $0.pauseStartedAt = nil
            }
            $0.endedAt = Date()
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
            startedAt: d.startedAt, finishedAt: d.endedAt ?? Date(),
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
        do {
            if FileManager.default.fileExists(atPath: url(draftFile).path) {
                try FileManager.default.removeItem(at: url(draftFile))
            }
            draft = nil
        } catch { notice = "Не удалось удалить черновик: \(error.localizedDescription)" }
    }

    func reload() {
        storageHealthy = true
        draft = load(WorkoutDraft?.self, file: draftFile) ?? nil
        history = load([WorkoutResult].self, file: historyFile) ?? []
        tick()
    }

    func editSet(_ id: UUID, reps: Int?, weight: Double?, seconds: Int?) {
        guard let d = draft, d.phase != .summary,
              let movement = d.movements.first(where: { $0.sets.contains(where: { $0.id == id }) }) else { return }
        let valid = movement.isTimed
            ? seconds.map { (1...3600).contains($0) } == true
            : (reps.map { (1...300).contains($0) } == true && weight.map { $0.isFinite && (0...250).contains($0) } == true)
        guard valid else { notice = "Проверь значения подхода"; return }
        commit { current in
            for i in current.movements.indices {
                if let index = current.movements[i].sets.firstIndex(where: { $0.id == id }) {
                    current.movements[i].sets[index].reps = movement.isTimed ? nil : reps
                    current.movements[i].sets[index].weightKg = movement.isTimed ? nil : weight
                    current.movements[i].sets[index].seconds = movement.isTimed ? seconds : nil
                }
            }
        }
    }

    func deleteSet(_ id: UUID) {
        guard draft?.phase != .summary else { return }
        commit { current in
            for i in current.movements.indices { current.movements[i].sets.removeAll { $0.id == id } }
        }
    }

    func reorder(from: Int, to: Int) {
        guard let d = draft, d.phase == .prepare, d.movements.indices.contains(from),
              d.movements.indices.contains(to) else { return }
        let selected = d.movements[d.currentIndex].id
        commit { current in
            let movement = current.movements.remove(at: from)
            current.movements.insert(movement, at: to)
            current.currentIndex = current.movements.firstIndex { $0.id == selected } ?? 0
        }
    }
}
