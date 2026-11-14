import XCTest
import PDFKit
import UserNotifications
@testable import SportFit

@MainActor final class JournalAndExportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func report(journal: JournalData = JournalData(), privacy: ReportPrivacy = .full) -> QuarterReport {
        QuarterReport.make(title: "Тестовый уровень", scope: "test", start: Date().addingTimeInterval(-86400), end: Date(), run: nil,
            history: [], measurements: [], xml: [], journal: journal, name: "PRIVATE PERSON", privacy: privacy)
    }
    func testJournalActivityAndGoalPersistAndCorruptFileCannotBeOverwritten() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let entry = ActivityEntry(date: Date(), metric: .steps, value: 1234)
        XCTAssertTrue(store.saveActivity(entry)); XCTAssertTrue(store.saveActivity(entry))
        XCTAssertTrue(store.saveGoal(QuarterGoal(scope: "test", metric: .weight, direction: .atMost, target: 70)))
        XCTAssertEqual(JournalStore(directory: directory).data.activity.count, 1)
        XCTAssertEqual(JournalStore(directory: directory).data.goals.first?.target, 70)
        let file = directory.appendingPathComponent("journal.v1.json"), broken = Data("broken".utf8)
        try broken.write(to: file)
        let corrupt = JournalStore(directory: directory)
        XCTAssertFalse(corrupt.saveActivity(entry))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
    func testBackupV4RestoresAllNewDataAndDisablesNotificationDelivery() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let engine = WorkoutEngine(directory: directory), measurements = MeasurementsStore(directory: directory)
        let store = LegacyFixture.store(directory: directory), profile = ProfileStore(directory: directory), journal = JournalStore(directory: directory)
        XCTAssertTrue(journal.saveActivity(ActivityEntry(date: Date(), metric: .sleep, value: 7.5)))
        XCTAssertTrue(journal.saveGoal(QuarterGoal(scope: "test", metric: .workouts, direction: .atLeast, target: 10)))
        XCTAssertTrue(journal.saveNote(DayNote(reason: "Test", text: "synthetic note")))
        let snapshot = report(journal: journal.data)
        XCTAssertTrue(journal.saveReport(snapshot)); XCTAssertTrue(journal.saveReport(snapshot))
        journal.change { $0.reminders.enabled = true }
        let backup = try BackupEnvelope.decode(BackupEnvelope.encode(SportFitBackup(engine: engine, measurements: measurements, store: store, profile: profile, journal: journal)))
        journal.change { $0 = JournalData() }
        try BackupRestore.restore(backup, engine: engine, measurements: measurements, store: store, profile: profile, journal: journal)
        XCTAssertEqual(journal.data.activity.first?.value, 7.5)
        XCTAssertEqual(journal.data.goals.count, 1); XCTAssertEqual(journal.data.notes.first?.text, "synthetic note")
        XCTAssertEqual(journal.data.reports.map(\.id), [snapshot.id]); XCTAssertFalse(journal.data.reminders.enabled)
        XCTAssertTrue(BackupVault.items(directory: directory).contains { $0.url.lastPathComponent.contains("before-restore") })
    }
    func testRestoreToAnotherContainerAndRepeatDoesNotDuplicateHistory() async throws {
        let source = try directory(), target = try directory(); defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let engine = WorkoutEngine(directory: source), store = LegacyFixture.store(directory: source), profile = ProfileStore(directory: source)
        engine.start(day: ProgramDay(dayOfWeek: "test", name: "test", exerciseIds: ["press_floor"]), date: Date(), store: store)
        engine.begin(); engine.complete(reps: 4, weight: 0, seconds: nil); engine.earlyFinish()
        let result = try XCTUnwrap(engine.finish(feeling: nil))
        let backup = SportFitBackup(engine: engine, measurements: MeasurementsStore(directory: source), store: store, profile: profile)
        let targetEngine = WorkoutEngine(directory: target), targetStore = LegacyFixture.store(directory: target), targetProfile = ProfileStore(directory: target), targetMeasurements = MeasurementsStore(directory: target)
        for _ in 0..<2 { try BackupRestore.restore(backup, engine: targetEngine, measurements: targetMeasurements, store: targetStore, profile: targetProfile) }
        XCTAssertEqual(targetEngine.history.map(\.id), [result.id])
        XCTAssertEqual(WorkoutEngine(directory: target).history.first?.movements.first?.sets.first?.reps, 4)
    }
    func testV3BackupWithoutJournalStillRestores() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let engine = WorkoutEngine(directory: directory), store = LegacyFixture.store(directory: directory), profile = ProfileStore(directory: directory), measurements = MeasurementsStore(directory: directory)
        let backup = SportFitBackup(engine: engine, measurements: measurements, store: store, profile: profile)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any]); json["format"] = "sportfit-backup-v3"; json.removeValue(forKey: "journal")
        let old = try JSONDecoder().decode(SportFitBackup.self, from: JSONSerialization.data(withJSONObject: json))
        try BackupRestore.restore(old, engine: engine, measurements: measurements, store: store, profile: profile)
        XCTAssertTrue(engine.canExport); XCTAssertTrue(JournalStore(directory: directory).data.activity.isEmpty)
    }
    func testInvalidNewDataIsRejectedBeforeReplacingExistingFiles() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let engine = WorkoutEngine(directory: directory), store = LegacyFixture.store(directory: directory), profile = ProfileStore(directory: directory), measurements = MeasurementsStore(directory: directory)
        let backup = SportFitBackup(engine: engine, measurements: measurements, store: store, profile: profile)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
        var journal = try XCTUnwrap(json["journal"] as? [String: Any]); journal["format"] = "future"; json["journal"] = journal
        let invalid = try JSONDecoder().decode(SportFitBackup.self, from: JSONSerialization.data(withJSONObject: json))
        let old = try Data(contentsOf: directory.appendingPathComponent(WorkoutDatabase.filename))
        XCTAssertThrowsError(try BackupRestore.restore(invalid, engine: engine, measurements: measurements, store: store, profile: profile))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(WorkoutDatabase.filename)), old)
    }
    func testPDFHasMultiplePagesAndRedactedExportsOmitPrivateText() async throws {
        var journal = JournalData()
        journal.notes = (0..<20).map { _ in DayNote(reason: "PRIVATE REASON", text: String(repeating: "Синтетический текст заметки. ", count: 30)) }
        let full = report(journal: journal)
        let pdf = try XCTUnwrap(PDFDocument(data: ReportExporter.pdf(full)))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("PRIVATE PERSON") == true)
        for privacy in [ReportPrivacy.metrics, .training] {
            let redacted = full.redacted(privacy)
            let text = ReportExporter.text(redacted), json = String(decoding: try redacted.json(), as: UTF8.self)
            XCTAssertFalse(text.contains("PRIVATE PERSON")); XCTAssertFalse(json.contains("PRIVATE REASON"))
            let pdf = try XCTUnwrap(PDFDocument(data: ReportExporter.pdf(redacted)))
            XCTAssertFalse(pdf.string?.contains("PRIVATE PERSON") == true)
            XCTAssertFalse(pdf.string?.contains("PRIVATE REASON") == true)
        }
    }
    func testNotificationRequestHasLocalTriggerAndNoMeasurementValues() async throws {
        let item = LocalReminder(id: "sportfit.test", date: Date().addingTimeInterval(120), title: "Тест", body: "Открой дневник", destination: "progress")
        let request = ReminderService.request(item)
        XCTAssertTrue(request.trigger is UNCalendarNotificationTrigger)
        XCTAssertEqual(request.content.userInfo["destination"] as? String, "progress")
        XCTAssertFalse(request.trigger?.repeats == true)
        XCTAssertEqual(request.identifier, item.id)
    }
    func testManualMeasurementImportDetectsConflictingUUIDInsteadOfSilentLoss() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeasurementsStore(directory: directory)
        XCTAssertTrue(store.add(date: Date(), weightKg: 75, waistCm: nil, bodyFatPercent: nil))
        var entry = try XCTUnwrap(store.entries.first); entry.weightKg = 90
        let file = directory.appendingPathComponent("import.json"); try JSONEncoder().encode([entry]).write(to: file)
        XCTAssertThrowsError(try store.importFile(file))
        XCTAssertEqual(store.entries.first?.weightKg, 75)
        let duplicate = BodyMeasurement(date: entry.measuredAt, weightKg: 75, waistCm: nil, bodyFatPercent: nil)
        try JSONEncoder().encode([duplicate]).write(to: file)
        try store.importFile(file)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(store.update(duplicate))
    }
}
