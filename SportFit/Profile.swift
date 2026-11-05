import SwiftUI

@MainActor final class ProfileStore: ObservableObject {
    @Published var profile = UserProfile()
    @Published private(set) var changes: [ScheduleChange] = []
    @Published var error: String?
    private var storageHealthy = true
    var canExport: Bool { storageHealthy && LocalFiles.recoveryError == nil }
    let directory: URL
    init(directory: URL = LocalFiles.directory) { self.directory = directory; reload() }
    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func reload() {
        storageHealthy = true
        do {
            if FileManager.default.fileExists(atPath: url("profile.v1.json").path) {
                profile = try JSONDecoder().decode(UserProfile.self, from: Data(contentsOf: url("profile.v1.json")))
            }
            if FileManager.default.fileExists(atPath: url("schedule.v1.json").path) {
                changes = try JSONDecoder().decode([ScheduleChange].self, from: Data(contentsOf: url("schedule.v1.json")))
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
