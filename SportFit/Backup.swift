import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let sportfitDataRestored = Notification.Name("SportFit.dataRestored")
}

/// User-owned local export. No upload is performed by this code.
struct SportFitBackup: Codable {
    let format: String
    let exportedAt: Date
    let workouts: [WorkoutResult]
    let activeWorkout: WorkoutDraft?
    let manualMeasurements: [BodyMeasurement]
    let legacySetRecords: [SetRecord]
    let catalog: ExerciseCatalog?
    let program: TrainingProgram?
    let archivedPrograms: [TrainingProgram]?
    let profile: UserProfile?
    let schedule: [ScheduleChange]?
    let runs: [ProgramRun]?
    let journal: JournalData?

    @MainActor
    init(engine: WorkoutEngine, measurements: MeasurementsStore, store: FitnessStore, profile: ProfileStore, journal: JournalStore? = nil) {
        self.format = "sportfit-backup-v4"
        self.exportedAt = Date()
        self.workouts = engine.history
        self.activeWorkout = engine.draft
        self.manualMeasurements = measurements.entries
        self.legacySetRecords = store.completedSets
        self.catalog = store.catalog
        self.program = store.program
        self.archivedPrograms = store.archivedPrograms
        self.profile = profile.profile
        self.schedule = profile.changes
        self.runs = profile.runs
        self.journal = (journal ?? JournalStore(directory: store.directory)).data
    }
}

struct BackupEnvelope: Codable {
    let format: String
    let sha256: String
    let payload: Data
    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func encode(_ backup: SportFitBackup) throws -> Data {
        let payload = try JSONEncoder().encode(backup)
        let bytes = try JSONEncoder().encode(BackupEnvelope(format: "sportfit-envelope-v1", sha256: checksum(payload), payload: payload))
        try DataValidation.require(bytes.count <= 100 * 1024 * 1024, "Копия превышает поддерживаемые 100 МБ")
        return bytes
    }
    static func decode(_ data: Data) throws -> SportFitBackup {
        // Legacy v1 exports had no checksum. Preserve the ability to recover them.
        if let envelope = try? JSONDecoder().decode(BackupEnvelope.self, from: data) {
            try DataValidation.require(envelope.format == "sportfit-envelope-v1" && checksum(envelope.payload) == envelope.sha256,
                                       "Не совпадает контрольная сумма резервной копии")
            return try JSONDecoder().decode(SportFitBackup.self, from: envelope.payload)
        }
        let legacy = try JSONDecoder().decode(SportFitBackup.self, from: data)
        try DataValidation.require(legacy.format == "sportfit-backup-v1", "Копии v2–v4 должны содержать контрольную сумму")
        return legacy
    }
}

struct SportFitBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var backup: SportFitBackup

    init(backup: SportFitBackup) {
        self.backup = backup
    }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoded = try BackupEnvelope.decode(bytes)
        guard ["sportfit-backup-v1", "sportfit-backup-v2", "sportfit-backup-v3", "sportfit-backup-v4"].contains(decoded.format) else {
            throw CocoaError(.fileReadUnknown)
        }
        backup = decoded
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: try BackupEnvelope.encode(backup))
    }
}

@MainActor enum BackupRestore {
    static func read(_ url: URL, store: FitnessStore) throws -> SportFitBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        try DataValidation.require(size <= 100 * 1024 * 1024, "Копия превышает 100 МБ")
        let data = try Data(contentsOf: url)
        try DataValidation.require(data.count <= 100 * 1024 * 1024, "Копия превышает 100 МБ")
        let backup = try BackupEnvelope.decode(data)
        try validate(backup, fallback: store.catalog)
        return backup
    }

    static func validate(_ backup: SportFitBackup, fallback: ExerciseCatalog?) throws {
        try DataValidation.require(["sportfit-backup-v1", "sportfit-backup-v2", "sportfit-backup-v3", "sportfit-backup-v4"].contains(backup.format), "Неизвестная версия копии")
        if backup.format != "sportfit-backup-v1" {
            try DataValidation.require(backup.catalog != nil && backup.program != nil && backup.profile != nil &&
                                       backup.archivedPrograms != nil && backup.schedule != nil, "Копия v2 неполна")
        }
        guard let catalog = backup.catalog ?? fallback else {
            throw DataValidation.Failure(message: "Необходим каталог упражнений")
        }
        try DataValidation.catalog(catalog)
        if backup.format == "sportfit-backup-v3" || backup.format == "sportfit-backup-v4" {
            try DataValidation.require(backup.runs != nil, "Копия v3 не содержит уровни")
        }
        if backup.format == "sportfit-backup-v4" { try DataValidation.require(backup.journal != nil, "Копия v4 не содержит дневник") }
        try backup.journal?.validate()
        let runs = backup.runs ?? []
        try ProgramRun.validate(runs, catalog: catalog)
        func runReferenceValid(_ id: UUID?, _ index: Int?) -> Bool {
            if id == nil { return index == nil }
            guard let id, let index, let run = runs.first(where: { $0.id == id }) else { return false }
            return run.workout(on: index) != nil
        }
        for plan in (backup.archivedPrograms ?? []) + [backup.program].compactMap({ $0 }) {
            try DataValidation.program(plan, catalog: catalog)
        }
        try DataValidation.require(Set(backup.workouts.map(\.id)).count == backup.workouts.count &&
                                   Set(backup.manualMeasurements.map(\.id)).count == backup.manualMeasurements.count &&
                                   Set(backup.legacySetRecords.map(\.id)).count == backup.legacySetRecords.count,
                                   "Копия содержит повторяющиеся записи")
        try DataValidation.require(backup.manualMeasurements.allSatisfy(MeasurementsStore.valid), "Некорректные измерения")
        let known = Set(catalog.exercises.map(\.id))
        let retiredDrafts = backup.journal?.retiredDrafts ?? []
        let workoutIDs = backup.workouts.map(\.id) + retiredDrafts.map(\.id) + [backup.activeWorkout?.id].compactMap { $0 }
        try DataValidation.require(Set(workoutIDs).count == workoutIDs.count, "Повторяющиеся тренировки и черновики")
        let allSets = backup.workouts.flatMap(\.movements).flatMap(\.sets) + (backup.activeWorkout?.movements.flatMap(\.sets) ?? []) + retiredDrafts.flatMap(\.movements).flatMap(\.sets)
        try DataValidation.require(Set(allSets.map(\.id)).count == allSets.count, "Повторяющиеся ID подходов")
        try DataValidation.require(Set((backup.schedule ?? []).map(\.id)).count == (backup.schedule ?? []).count, "Повторяющиеся переносы")
        func movementsValid(_ movements: [WorkoutMovement]) -> Bool {
            let sets = movements.flatMap(\.sets)
            return !movements.isEmpty && Set(movements.map(\.id)).count == movements.count &&
                Set(sets.map(\.id)).count == sets.count && movements.allSatisfy { movement in
                    known.contains(movement.exerciseId) && known.contains(movement.sourceId) &&
                    movement.sets.allSatisfy { actual in
                        if movement.isTimed { return actual.seconds.map { (1...3600).contains($0) } == true && (actual.otherSideSeconds.map { (1...3600).contains($0) } ?? true) }
                        return actual.reps.map { (0...300).contains($0) } == true &&
                            actual.weightKg.map { $0.isFinite && (0...250).contains($0) } == true
                    }
                }
        }
        for draft in retiredDrafts {
            try DataValidation.require(draft.movements.indices.contains(draft.currentIndex) && movementsValid(draft.movements) && runReferenceValid(draft.runId, draft.runDayIndex), "Повреждён архивный черновик")
        }
        for workout in backup.workouts {
            try DataValidation.require(SportDate.from(workout.date) != nil && workout.durationSeconds >= 0 &&
                                       workout.finishedAt >= workout.startedAt && movementsValid(workout.movements) &&
                                       runReferenceValid(workout.runId, workout.runDayIndex),
                                       "Повреждённая тренировка в копии")
        }
        for run in runs {
            for day in run.days where day.outcome == .completed || day.outcome == .partial {
                let results = run.results(on: day.dayIndex, history: backup.workouts)
                try DataValidation.require(day.outcome == .completed ? results.contains(where: \.isComplete) : !results.isEmpty,
                                           "Закрытый день не содержит результата")
            }
        }
        if let draft = backup.activeWorkout {
            try DataValidation.require(SportDate.from(draft.date) != nil && draft.movements.indices.contains(draft.currentIndex) &&
                                       movementsValid(draft.movements) && draft.elapsedPausedSeconds.isFinite && draft.elapsedPausedSeconds >= 0 &&
                                       (draft.exerciseSecondsLeft.map { (0...3600).contains($0) } ?? true) &&
                                       (draft.firstSideSeconds.map { (1...3600).contains($0) } ?? true) &&
                                       (draft.currentSide.map { [1, 2].contains($0) } ?? true) &&
                                       (draft.exerciseEndsAt.map { $0.timeIntervalSinceReferenceDate.isFinite } ?? true) &&
                                       !backup.workouts.contains(where: { $0.id == draft.id }) &&
                                       runReferenceValid(draft.runId, draft.runDayIndex), "Некорректный черновик")
            if let id = draft.runId, let run = runs.first(where: { $0.id == id }) {
                try DataValidation.require(run.closedAt == nil && !run.isRetired && run.currentDay == draft.runDayIndex, "Черновик относится к закрытому дню")
            }
        }
        if let profile = backup.profile {
            try DataValidation.require(profile.heightCm.map { $0.isFinite && (50...250).contains($0) } ?? true, "Некорректный рост")
            try DataValidation.require(profile.targetWeightKg.map { $0.isFinite && (20...400).contains($0) } ?? true, "Некорректная цель")
        }
        for change in backup.schedule ?? [] {
            try DataValidation.require(SportDate.from(change.originalDate) != nil &&
                                       (change.movedTo.map { SportDate.from($0) != nil } ?? true), "Некорректный перенос")
        }
    }

    static func restore(_ backup: SportFitBackup, engine: WorkoutEngine, measurements: MeasurementsStore,
                        store: FitnessStore, profile: ProfileStore, journal: JournalStore? = nil) throws {
        try validate(backup, fallback: store.catalog)
        let currentJournal = journal ?? JournalStore(directory: store.directory)
        if engine.canExport && measurements.canExport && store.canExport && profile.canExport && currentJournal.canExport {
            try BackupVault.save(SportFitBackup(engine: engine, measurements: measurements, store: store, profile: profile, journal: currentJournal), directory: store.directory, kind: "before-restore")
        }
        let encoder = JSONEncoder()
        var restoredJournal = backup.journal ?? JournalData()
        // OS permission and delivery are not portable to another device.
        restoredJournal.reminders.enabled = false
        var files: [String: Data] = [
            "journal.v1.json": try encoder.encode(restoredJournal),
            "program_runs.v1.json": try encoder.encode(backup.runs ?? []),
            "workout_history.v1.json": try encoder.encode(backup.workouts),
            WorkoutDatabase.filename: try WorkoutDatabase.image(backup.workouts),
            "active_workout.v1.json": try encoder.encode(backup.activeWorkout),
            "body_measurements.v1.json": try encoder.encode(backup.manualMeasurements),
            "completed_sets.json": try encoder.encode(backup.legacySetRecords)
        ]
        if let catalog = backup.catalog { files["exercises.v1.json"] = try encoder.encode(catalog) }
        if let program = backup.program { files["program_12w.v1.json"] = try encoder.encode(program) }
        if let archive = backup.archivedPrograms { files["program_archive.v1.json"] = try encoder.encode(archive) }
        if let value = backup.profile { files["profile.v1.json"] = try encoder.encode(value) }
        if let value = backup.schedule { files["schedule.v1.json"] = try encoder.encode(value) }
        try LocalFiles.restore(files, directory: store.directory)
        store.reload()
        measurements.reload()
        profile.reload()
        engine.reload()
        journal?.reload()
        NotificationCenter.default.post(name: .sportfitDataRestored, object: store.directory)
    }
}
