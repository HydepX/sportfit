import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

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

    @MainActor
    init(engine: WorkoutEngine, measurements: MeasurementsStore, store: FitnessStore, profile: ProfileStore) {
        self.format = "sportfit-backup-v2"
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
        return try JSONEncoder().encode(BackupEnvelope(format: "sportfit-envelope-v1", sha256: checksum(payload), payload: payload))
    }
    static func decode(_ data: Data) throws -> SportFitBackup {
        // Legacy v1 exports had no checksum. Preserve the ability to recover them.
        if let envelope = try? JSONDecoder().decode(BackupEnvelope.self, from: data) {
            try DataValidation.require(envelope.format == "sportfit-envelope-v1" && checksum(envelope.payload) == envelope.sha256,
                                       "Не совпадает контрольная сумма резервной копии")
            return try JSONDecoder().decode(SportFitBackup.self, from: envelope.payload)
        }
        let legacy = try JSONDecoder().decode(SportFitBackup.self, from: data)
        try DataValidation.require(legacy.format == "sportfit-backup-v1", "Копия v2 должна содержать контрольную сумму")
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
        guard ["sportfit-backup-v1", "sportfit-backup-v2"].contains(decoded.format) else {
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
        let data = try Data(contentsOf: url)
        try DataValidation.require(data.count <= 100 * 1024 * 1024, "Копия превышает 100 МБ")
        let backup = try BackupEnvelope.decode(data)
        try validate(backup, fallback: store.catalog)
        return backup
    }

    static func validate(_ backup: SportFitBackup, fallback: ExerciseCatalog?) throws {
        try DataValidation.require(["sportfit-backup-v1", "sportfit-backup-v2"].contains(backup.format), "Неизвестная версия копии")
        if backup.format == "sportfit-backup-v2" {
            try DataValidation.require(backup.catalog != nil && backup.program != nil && backup.profile != nil &&
                                       backup.archivedPrograms != nil && backup.schedule != nil, "Копия v2 неполна")
        }
        guard let catalog = backup.catalog ?? fallback else {
            throw DataValidation.Failure(message: "Необходим каталог упражнений")
        }
        try DataValidation.catalog(catalog)
        for plan in (backup.archivedPrograms ?? []) + [backup.program].compactMap({ $0 }) {
            try DataValidation.program(plan, catalog: catalog)
        }
        try DataValidation.require(Set(backup.workouts.map(\.id)).count == backup.workouts.count &&
                                   Set(backup.manualMeasurements.map(\.id)).count == backup.manualMeasurements.count &&
                                   Set(backup.legacySetRecords.map(\.id)).count == backup.legacySetRecords.count,
                                   "Копия содержит повторяющиеся записи")
        try DataValidation.require(backup.manualMeasurements.allSatisfy(MeasurementsStore.valid), "Некорректные измерения")
        let known = Set(catalog.exercises.map(\.id))
        let allSets = backup.workouts.flatMap(\.movements).flatMap(\.sets) + (backup.activeWorkout?.movements.flatMap(\.sets) ?? [])
        try DataValidation.require(Set(allSets.map(\.id)).count == allSets.count, "Повторяющиеся ID подходов")
        try DataValidation.require(Set((backup.schedule ?? []).map(\.id)).count == (backup.schedule ?? []).count, "Повторяющиеся переносы")
        func movementsValid(_ movements: [WorkoutMovement]) -> Bool {
            let sets = movements.flatMap(\.sets)
            return !movements.isEmpty && Set(movements.map(\.id)).count == movements.count &&
                Set(sets.map(\.id)).count == sets.count && movements.allSatisfy { movement in
                    known.contains(movement.exerciseId) && known.contains(movement.sourceId) &&
                    movement.sets.allSatisfy { actual in
                        if movement.isTimed { return actual.seconds.map { (1...3600).contains($0) } == true }
                        return actual.reps.map { (0...300).contains($0) } == true &&
                            actual.weightKg.map { $0.isFinite && (0...250).contains($0) } == true
                    }
                }
        }
        for workout in backup.workouts {
            try DataValidation.require(SportDate.from(workout.date) != nil && workout.durationSeconds >= 0 &&
                                       workout.finishedAt >= workout.startedAt && movementsValid(workout.movements),
                                       "Повреждённая тренировка в копии")
        }
        if let draft = backup.activeWorkout {
            try DataValidation.require(SportDate.from(draft.date) != nil && draft.movements.indices.contains(draft.currentIndex) &&
                                       movementsValid(draft.movements) && draft.elapsedPausedSeconds >= 0 &&
                                       !backup.workouts.contains(where: { $0.id == draft.id }), "Некорректный черновик")
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
                        store: FitnessStore, profile: ProfileStore) throws {
        try validate(backup, fallback: store.catalog)
        let encoder = JSONEncoder()
        var files: [String: Data] = [
            "workout_history.v1.json": try encoder.encode(backup.workouts),
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
    }
}
