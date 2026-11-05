import Foundation
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

    @MainActor
    init(engine: WorkoutEngine, measurements: MeasurementsStore, store: FitnessStore) {
        self.format = "sportfit-backup-v1"
        self.exportedAt = Date()
        self.workouts = engine.history
        self.activeWorkout = engine.draft
        self.manualMeasurements = measurements.entries
        self.legacySetRecords = store.completedSets
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
        let decoded = try JSONDecoder().decode(SportFitBackup.self, from: bytes)
        guard decoded.format == "sportfit-backup-v1" else {
            throw CocoaError(.fileReadUnknown)
        }
        backup = decoded
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(backup))
    }
}
