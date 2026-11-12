import SwiftUI

@MainActor final class ProfileStore: ObservableObject {
    @Published var profile = UserProfile()
    @Published private(set) var changes: [ScheduleChange] = []
    @Published private(set) var runs: [ProgramRun] = []
    var activeRun: ProgramRun? { runs.first { $0.closedAt == nil } }
    @Published var error: String?
    private var storageHealthy = true
    var canExport: Bool { storageHealthy && LocalFiles.recoveryError == nil }
    let directory: URL
    init(directory: URL = LocalFiles.directory) { self.directory = directory; reload() }
    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func reload() {
        storageHealthy = true
        do {
            profile = UserProfile()
            changes = []
            if FileManager.default.fileExists(atPath: url("profile.v1.json").path) {
                profile = try JSONDecoder().decode(UserProfile.self, from: Data(contentsOf: url("profile.v1.json")))
            }
            if FileManager.default.fileExists(atPath: url("schedule.v1.json").path) {
                changes = try JSONDecoder().decode([ScheduleChange].self, from: Data(contentsOf: url("schedule.v1.json")))
            }
            runs = []
            if FileManager.default.fileExists(atPath: url("program_runs.v1.json").path) {
                let loaded = try JSONDecoder().decode([ProgramRun].self, from: Data(contentsOf: url("program_runs.v1.json")))
                try DataValidation.require(Set(loaded.map(\.id)).count == loaded.count && loaded.filter { $0.closedAt == nil }.count <= 1,
                                           "Повреждён список уровней")
                for run in loaded { try run.validateStructure() }
                runs = loaded
            }
        } catch { storageHealthy = false; self.error = "Ошибка чтения профиля: \(error.localizedDescription)" }
    }
    func save() {
        guard storageHealthy, LocalFiles.recoveryError == nil else { error = "Сначала восстанови данные из копии"; return }
        do {
            try DataValidation.require(profile.heightCm.map { $0.isFinite && (50...250).contains($0) } ?? true, "Проверь рост")
            try DataValidation.require(profile.targetWeightKg.map { $0.isFinite && (20...400).contains($0) } ?? true, "Проверь целевой вес")
            try JSONEncoder().encode(profile).write(to: url("profile.v1.json"), options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
    private func saveRuns(_ updated: [ProgramRun]) {
        guard canExport else { error = "Сначала восстанови данные из копии"; return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: url("program_runs.v1.json"), options: .atomic)
            runs = updated
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func startRun(title: String, program: TrainingProgram, catalog: ExerciseCatalog, draft: WorkoutDraft?) {
        do {
            try DataValidation.require(activeRun == nil, "Сначала закрой текущий уровень")
            try DataValidation.require(draft == nil, "Сначала заверши или удали текущий черновик; его данные сохранены")
            let run = ProgramRun(title: title.trimmingCharacters(in: .whitespacesAndNewlines), program: program)
            try run.validate(catalog: catalog)
            saveRuns(runs + [run])
        } catch { self.error = error.localizedDescription }
    }
    func closeDay(history: [WorkoutResult], draft: WorkoutDraft?, allowIncomplete: Bool) {
        guard let index = runs.firstIndex(where: { $0.closedAt == nil }) else { return }
        do {
            try DataValidation.require(draft == nil, "Сначала сохрани результат или удали черновик")
            var updated = runs
            try updated[index].closeDay(history: history, allowIncomplete: allowIncomplete)
            saveRuns(updated)
        } catch { self.error = error.localizedDescription }
    }
    func closeRun(draft: WorkoutDraft?, allowIncomplete: Bool) {
        guard let index = runs.firstIndex(where: { $0.closedAt == nil }) else { return }
        do {
            try DataValidation.require(draft == nil, "Сначала сохрани результат или удали черновик")
            var updated = runs
            try updated[index].close(allowIncomplete: allowIncomplete)
            saveRuns(updated)
        } catch { self.error = error.localizedDescription }
    }
    func addExtraRest(now: Date = Date()) {
        guard let index = runs.firstIndex(where: { $0.closedAt == nil }), runs[index].currentDay != nil else { return }
        guard !runs[index].extraRests.contains(where: { SportDate.calendar.isDate($0, inSameDayAs: now) }) else {
            error = "Дополнительный отдых сегодня уже отмечен"; return
        }
        var updated = runs
        updated[index].extraRests.append(now)
        saveRuns(updated)
    }
    func change(programId: String, date: String, movedTo: String?, skipped: Bool) {
        guard storageHealthy, LocalFiles.recoveryError == nil else { error = "Сначала восстанови данные из копии"; return }
        var updated = changes.filter { !($0.programId == programId && $0.originalDate == date) }
        if movedTo != nil || skipped {
            updated.append(ScheduleChange(programId: programId, originalDate: date, movedTo: movedTo, skipped: skipped))
        }
        do {
            try JSONEncoder().encode(updated).write(to: url("schedule.v1.json"), options: .atomic)
            changes = updated
        } catch { self.error = error.localizedDescription }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject private var store: ProfileStore
    var body: some View {
        Form {
            TextField("Имя", text: $store.profile.name)
            TextField("Рост, см", value: $store.profile.heightCm, format: .number).keyboardType(.decimalPad)
            TextField("Целевой вес, кг", value: $store.profile.targetWeightKg, format: .number).keyboardType(.decimalPad)
            TextField("Моя цель", text: $store.profile.goal, axis: .vertical)
            Button("Сохранить") { store.save() }
            if let error = store.error { Text(error).foregroundStyle(.red) }
            Text("Профиль и цели хранятся только на устройстве и включаются в резервную копию.")
        }.navigationTitle("Личные данные и цели")
    }
}
