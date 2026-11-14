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
        LocalFiles.recoverIfNeeded(directory: directory)
        draft = load(WorkoutDraft?.self, file: draftFile) ?? nil
        loadHistory()
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
        suspendAutoplay()
        tick(advanceRest: false)
    }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }
    private func loadHistory() {
        do { history = try WorkoutDatabase(directory: directory).load() }
        catch { storageHealthy = false; notice = "История не прочитана; исходные файлы сохранены: \(error.localizedDescription)" }
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

    func start(run: ProgramRun, store: FitnessStore, guided: Bool = false) {
        guard run.closedAt == nil, !run.isRetired, let index = run.currentDay, let day = run.workout(on: index) else {
            notice = "В этот день отдых или уровень закрыт"; return
        }
        start(day: day, date: Date(), store: store, run: run, runDayIndex: index, guided: guided)
    }

    func start(day: ProgramDay, date: Date, store: FitnessStore, run: ProgramRun? = nil, runDayIndex: Int? = nil, guided: Bool = false) {
        guard draft == nil else { notice = "Сначала заверши или удали незавершённую тренировку"; return }
        let program = run?.program ?? store.program
        let alreadySaved = run.map { run in
            history.contains { $0.runId == run.id && $0.runDayIndex == runDayIndex && $0.isComplete }
        } ?? history.contains { $0.runId == nil && $0.programId == program?.programId && $0.date == SportDate.key(date) }
        guard !alreadySaved else {
            notice = "За этот день уже есть результат. Открой его в журнале"; return
        }
        let sourceDate = run.flatMap { $0.sourceDate(for: runDayIndex ?? -1) } ?? date
        let movements = day.exerciseIds.enumerated().compactMap { position, sourceId -> WorkoutMovement? in
            let resolved = program?.conditionalSubstitutions?[sourceId]?.fallback ?? sourceId
            guard let exercise = store.exercise(resolved) else { return nil }
            return WorkoutMovement(sourceId: sourceId, exercise: exercise, prescription: program?.prescription(exercise.id, on: sourceDate, position: position))
        }
        guard !movements.isEmpty, movements.count == day.exerciseIds.count, let programId = program?.programId else {
            notice = "Не удалось сопоставить упражнения с библиотекой"
            return
        }
        var d = WorkoutDraft(date: SportDate.key(date), programId: programId,
                             title: day.name, movements: movements)
        d.runId = run?.id
        d.runDayIndex = runDayIndex
        d.guided = guided
        if save(d, file: draftFile) { draft = d; if guided { begin() } }
    }

    func begin(clearanceConfirmed: Bool = false, now: Date = Date()) {
        guard let d = draft, d.phase == .prepare, d.movements.indices.contains(d.currentIndex) else { return }
        let movement = d.movements[d.currentIndex]
        guard movement.prescription?.requiresClearance != true || movement.clearanceConfirmed == true || clearanceConfirmed else {
            notice = movement.prescription?.clearanceNote ?? "Для этого упражнения нужно разрешение врача. Без него пропусти упражнение."
            return
        }
        commit {
            if clearanceConfirmed { $0.movements[$0.currentIndex].clearanceConfirmed = true }
            $0.phase = .active
            $0.autoplaySuspended = false
            $0.currentSide = movement.isTimedPerSide ? 1 : nil
            $0.firstSideSeconds = nil
            let seconds = movement.plannedSeconds.flatMap { (1...3600).contains($0) ? $0 : nil }
            $0.exerciseSecondsLeft = seconds
            $0.exerciseEndsAt = $0.guided == true ? seconds.map { now.addingTimeInterval(Double($0)) } : nil
        }
    }

    /// Opt old drafts into the player without replacing their UUID, plan or sets.
    func enableGuidedMode() {
        guard let d = draft, d.guided != true, d.movements.indices.contains(d.currentIndex) else { return }
        commit {
            $0.guided = true; $0.autoplaySuspended = true
            let movement = $0.movements[$0.currentIndex]
            let seconds = movement.plannedSeconds.flatMap { (1...3600).contains($0) ? $0 : nil }
            $0.exerciseSecondsLeft = seconds
            $0.restAfterLastSet = movement.sets.count >= (movement.prescription?.sets ?? 1)
            if $0.restAfterLastSet, $0.phase == .active || ($0.phase == .paused && $0.pausedPhase == .active) {
                if $0.phase == .paused { $0.pausedPhase = .rest } else { $0.phase = .rest }
                $0.restEndsAt = nil; $0.restSecondsLeft = 0; $0.restWaitsForUser = true
                $0.exerciseEndsAt = nil; $0.exerciseSecondsLeft = nil
            } else if $0.phase == .active { $0.exerciseEndsAt = seconds.map { Date().addingTimeInterval(Double($0)) } }
        }
        if draft?.phase == .prepare { begin() }
    }
    func suspendAutoplay() {
        guard draft?.guided == true, draft?.autoplaySuspended != true else { return }
        commit { $0.autoplaySuspended = true }
    }
    func exerciseRemaining(now: Date = Date()) -> Int? {
        guard let d = draft else { return nil }
        if d.phase == .paused { return d.exerciseSecondsLeft }
        guard let end = d.exerciseEndsAt else { return nil }
        return max(0, Int(ceil(end.timeIntervalSince(now))))
    }
    func completePlanned(now: Date = Date()) {
        guard let d = draft, d.movements.indices.contains(d.currentIndex) else { return }
        let movement = d.movements[d.currentIndex]
        complete(reps: movement.isTimed ? nil : movement.plannedReps,
                 weight: movement.isTimed ? nil : 0,
                 seconds: movement.isTimedPerSide ? (d.firstSideSeconds ?? movement.plannedSeconds) : (movement.isTimed ? movement.plannedSeconds : nil),
                 otherSeconds: movement.isTimedPerSide ? movement.plannedSeconds : nil, now: now)
    }

    func complete(reps: Int?, weight: Double?, seconds: Int?, otherSeconds: Int? = nil, now: Date = Date()) {
        guard let d = draft, (d.phase == .active || (d.phase == .paused && d.pausedPhase == .active)), d.movements.indices.contains(d.currentIndex) else { return }
        let movement = d.movements[d.currentIndex]
        guard movement.prescription?.requiresClearance != true || movement.clearanceConfirmed == true else {
            notice = "Для упражнения не подтверждено разрешение врача"; return
        }
        if let last = movement.sets.last, now.timeIntervalSince(last.completedAt) < 1 {
            notice = "Этот подход уже отмечен"; return
        }
        if movement.isTimed {
            guard let seconds, (1...3600).contains(seconds), otherSeconds.map({ (1...3600).contains($0) }) ?? true else {
                notice = "Укажи длительность от 1 до 3600 секунд"; return
            }
        } else {
            guard let reps, (1...300).contains(reps),
                  let weight, weight.isFinite, (0...250).contains(weight) else {
                notice = "Проверь повторения (0–300) и вес (0–250 кг)"; return
            }
        }
        commit { d in
            if let paused = d.pauseStartedAt { d.elapsedPausedSeconds += now.timeIntervalSince(paused) }
            d.pauseStartedAt = nil; d.pausedPhase = nil
            d.movements[d.currentIndex].sets.append(
                ActualSet(reps: reps, weightKg: weight, seconds: seconds, completedAt: now, otherSideSeconds: movement.isTimedPerSide ? otherSeconds : nil))
            // Guided playback follows the prescribed set count, including multi-set exercises.
            d.movements[d.currentIndex].skipped = false
            d.movements[d.currentIndex].skipReason = nil
            let rest = movement.prescription?.restSeconds ?? movement.sourceRestSeconds
            // Missing prescriptions are explicit; never invent the same rest for every exercise.
            d.restSecondsLeft = rest ?? 0
            d.restWaitsForUser = (rest ?? 0) <= 0
            d.phase = d.guided == true || (rest ?? 0) > 0 ? .rest : .active
            d.restEndsAt = rest.flatMap { $0 > 0 ? now.addingTimeInterval(Double($0)) : nil }
            d.restAfterLastSet = d.movements[d.currentIndex].sets.count >= (movement.prescription?.sets ?? 1)
            d.exerciseEndsAt = nil
            d.exerciseSecondsLeft = nil
        }
    }

    func addAnotherSet() {
        guard draft?.phase == .rest else { return }
        if draft?.guided == true {
            commit { $0.phase = .prepare; $0.restEndsAt = nil; $0.restSecondsLeft = 0 }
            begin()
        } else {
            commit { $0.phase = .active; $0.restEndsAt = nil; $0.restAfterLastSet = false }
        }
    }
    func continueAfterRest(now: Date = Date()) {
        guard let d = draft, d.phase == .rest else { return }
        if d.guided == true && !d.restAfterLastSet {
            if commit({ $0.phase = .prepare; $0.restEndsAt = nil }) { begin(now: now) }
        } else { nextExercise(now: now) }
    }
    func restartCurrentSet(now: Date = Date()) {
        guard let d = draft, d.phase == .active || d.phase == .rest || d.phase == .paused else { return }
        if commit({ current in
            if current.phase == .rest || current.pausedPhase == .rest { _ = current.movements[current.currentIndex].sets.popLast() }
            if let paused = current.pauseStartedAt { current.elapsedPausedSeconds += now.timeIntervalSince(paused) }
            current.pauseStartedAt = nil; current.pausedPhase = nil
            current.phase = .prepare; current.restEndsAt = nil; current.exerciseEndsAt = nil
        }) { begin(now: now) }
    }

    func nextExercise(now: Date = Date()) {
        guard let d = draft, d.phase != .paused, d.phase != .summary else { return }
        if d.currentIndex + 1 >= d.movements.count {
            commit { $0.phase = .summary; $0.endedAt = now; $0.restEndsAt = nil; $0.exerciseEndsAt = nil }
        } else {
            commit {
                $0.currentIndex += 1
                $0.phase = .prepare
                $0.restEndsAt = nil
                $0.exerciseEndsAt = nil
            }
            if draft?.guided == true { begin(now: now) }
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
            $0.exerciseEndsAt = nil
        }
        if draft?.guided == true { begin() }
    }

    func skip(reason: String) {
        guard let d = draft, d.phase != .summary, d.movements.indices.contains(d.currentIndex) else { return }
        if commit({
            if let paused = $0.pauseStartedAt { $0.elapsedPausedSeconds += Date().timeIntervalSince(paused) }
            $0.pauseStartedAt = nil; $0.pausedPhase = nil; $0.phase = .prepare
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
            if current.phase == .active, let end = current.exerciseEndsAt {
                current.exerciseSecondsLeft = max(0, Int(ceil(end.timeIntervalSinceNow)))
            }
            current.pausedPhase = current.phase
            current.exerciseEndsAt = nil
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
                current.restEndsAt = current.restSecondsLeft > 0 || current.restWaitsForUser != true
                    ? Date().addingTimeInterval(Double(current.restSecondsLeft)) : nil
            }
            if current.phase == .active, current.guided == true, let seconds = current.exerciseSecondsLeft {
                current.exerciseEndsAt = Date().addingTimeInterval(Double(seconds))
            }
            current.autoplaySuspended = false
            current.pausedPhase = nil
        }
        tick()
    }

    func extendRest(_ seconds: Int, now: Date = Date()) {
        guard seconds > 0, let d = draft,
              d.phase == .rest || (d.phase == .paused && d.pausedPhase == .rest) else { return }
        commit {
            $0.restWaitsForUser = false
            if $0.phase == .rest {
                $0.restEndsAt = max($0.restEndsAt ?? now, now).addingTimeInterval(TimeInterval(seconds))
                $0.restSecondsLeft = max(0, Int(ceil($0.restEndsAt!.timeIntervalSince(now))))
            } else { $0.restSecondsLeft += seconds }
        }
    }
    func tick(now: Date = Date(), advanceRest: Bool = true) {
        guard let d = draft, d.movements.indices.contains(d.currentIndex) else { return }
        if d.guided == true, d.phase == .active, let end = d.exerciseEndsAt, end <= now {
            let movement = d.movements[d.currentIndex]
            if movement.isTimedPerSide, d.currentSide != 2, let seconds = movement.plannedSeconds {
                commit {
                    $0.currentSide = 2; $0.firstSideSeconds = seconds; $0.exerciseSecondsLeft = seconds
                    if advanceRest && $0.autoplaySuspended != true {
                        $0.exerciseEndsAt = now.addingTimeInterval(Double(seconds))
                    } else {
                        $0.exerciseEndsAt = nil; $0.phase = .paused; $0.pausedPhase = .active; $0.pauseStartedAt = end
                    }
                }
            } else {
                // At most one set; never replay unseen movements after a lock/relaunch.
                completePlanned(now: now)
            }
        } else if d.phase == .rest, let end = d.restEndsAt, end <= now {
            if d.guided == true {
                if advanceRest && d.autoplaySuspended != true { continueAfterRest(now: now) }
            } else { commit { $0.phase = .active; $0.restEndsAt = nil } }
        }
    }
    func restRemaining(now: Date = Date()) -> Int {
        guard let d = draft, d.phase == .rest, let end = d.restEndsAt else { return 0 }
        return max(0, Int(ceil(end.timeIntervalSince(now))))
    }
    func earlyFinish() {
        commit {
            if let paused = $0.pauseStartedAt {
                $0.elapsedPausedSeconds += Date().timeIntervalSince(paused)
                $0.pauseStartedAt = nil
            }
            $0.endedAt = Date()
            $0.finishedEarly = true
            $0.exerciseEndsAt = nil
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
            finishedEarly: d.finishedEarly, movements: d.movements, runId: d.runId, runDayIndex: d.runDayIndex)
        // Idempotency: if a saved workout is re-opened, keep one result per UUID.
        if !history.contains(where: { $0.id == result.id }) {
            guard canExport else { notice = "Сначала восстанови данные из копии"; return nil }
            do { try WorkoutDatabase(directory: directory).append(result); history.append(result) }
            catch { notice = "Результат не сохранён: \(error.localizedDescription)"; return nil }
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
        loadHistory()
        suspendAutoplay()
        tick(advanceRest: false)
    }

    func editSet(_ id: UUID, reps: Int?, weight: Double?, seconds: Int?, otherSeconds: Int? = nil) {
        guard let d = draft,
              let movement = d.movements.first(where: { $0.sets.contains(where: { $0.id == id }) }) else { return }
        let valid = movement.isTimed
            ? seconds.map { (1...3600).contains($0) } == true
            : (reps.map { (1...300).contains($0) } == true && weight.map { $0.isFinite && (0...250).contains($0) } == true)
        guard valid && (otherSeconds.map { (1...3600).contains($0) } ?? true) else { notice = "Проверь значения подхода"; return }
        commit { current in
            for i in current.movements.indices {
                if let index = current.movements[i].sets.firstIndex(where: { $0.id == id }) {
                    current.movements[i].sets[index].reps = movement.isTimed ? nil : reps
                    current.movements[i].sets[index].weightKg = movement.isTimed ? nil : weight
                    current.movements[i].sets[index].seconds = movement.isTimed ? seconds : nil
                    current.movements[i].sets[index].otherSideSeconds = movement.isTimedPerSide ? otherSeconds : nil
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
