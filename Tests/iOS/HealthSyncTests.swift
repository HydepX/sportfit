import XCTest
@testable import SportFit

@MainActor private final class MockHealthClient: HealthQueryClient {
    var buildEnabled = true
    var available = true
    var authorizationCalls = 0
    var queries: [HealthField] = []
    var values: [HealthField: HealthRecord] = [:]
    var errors = Set<HealthField>()
    var authorizationError = false
    func authorize() async throws {
        authorizationCalls += 1
        if authorizationError { throw DataValidation.Failure(message: "Test authorization error") }
    }
    func read(_ field: HealthField, now: Date) async throws -> HealthRecord? {
        queries.append(field)
        if errors.contains(field) { throw DataValidation.Failure(message: "Test query error") }
        return values[field]
    }
}

@MainActor final class HealthSyncTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testNoAutomaticPermissionPromptAndExactlyThreeExplicitQueries() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockHealthClient()
        let reader = HealthReader(client: client, directory: directory)
        await reader.refresh()
        XCTAssertEqual(client.authorizationCalls, 0)
        XCTAssertTrue(client.queries.isEmpty)
        await reader.connect()
        XCTAssertEqual(client.authorizationCalls, 1)
        XCTAssertEqual(client.queries, HealthField.allCases)
        XCTAssertTrue(reader.cache.snapshots.allSatisfy { $0.status == .empty && $0.record == nil })
    }
    func testIndependentFailuresAreNotSilentlyEmpty() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockHealthClient(); client.errors.insert(.pulse)
        let reader = HealthReader(client: client, directory: directory)
        await reader.connect()
        XCTAssertEqual(reader.cache.snapshots.first { $0.field == .pulse }?.status, .failed)
        XCTAssertEqual(reader.cache.snapshots.first { $0.field == .weight }?.status, .empty)
        XCTAssertNil(reader.cache.snapshots.first { $0.field == .pulse }?.successfulQueryAt)
    }
    func testAutomaticRefreshDebouncesAndManualRefreshBypassesThrottle() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockHealthClient(); let reader = HealthReader(client: client, directory: directory)
        let now = Date()
        await reader.connect(now: now)
        await reader.refresh(now: now.addingTimeInterval(299))
        XCTAssertEqual(client.queries.count, 3)
        await reader.refresh(force: true, now: now.addingTimeInterval(299))
        XCTAssertEqual(client.queries.count, 6)
        XCTAssertEqual(client.authorizationCalls, 1)
    }
    func testNativeCacheSurvivesReloadWithoutOverwritingManualMeasurement() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockHealthClient()
        client.values[.weight] = HealthRecord(id: "hk:test-weight", field: .weight, value: 70, start: Date(), end: Date(), source: "Test")
        let manual = MeasurementsStore(directory: directory)
        XCTAssertTrue(manual.add(date: Date(), weightKg: 80, waistCm: nil, bodyFatPercent: nil))
        let reader = HealthReader(client: client, directory: directory)
        await reader.connect()
        XCTAssertEqual(MeasurementsStore(directory: directory).latest?.weightKg, 80)
        let reloaded = HealthReader(client: client, directory: directory)
        XCTAssertEqual(reloaded.cache.snapshots.first { $0.field == .weight }?.record?.value, 70)
        let excluded = try directory.appendingPathComponent("HealthLocal").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(excluded.isExcludedFromBackup, true)
        let backup = SportFitBackup(engine: WorkoutEngine(directory: directory), measurements: manual,
            store: FitnessStore(directory: directory), profile: ProfileStore(directory: directory))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(backup), as: UTF8.self).contains("hk:test-weight"))
    }
    func testAuthorizationFailureAndDisabledVariantDoNotQueryHealthData() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockHealthClient(); client.authorizationError = true
        let reader = HealthReader(client: client, directory: directory)
        await reader.connect()
        XCTAssertTrue(client.queries.isEmpty)
        XCTAssertFalse(reader.cache.connectionRequested)
        let disabled = MockHealthClient(); disabled.buildEnabled = false
        await HealthReader(client: disabled, directory: directory).connect()
        XCTAssertEqual(disabled.authorizationCalls, 0)
    }
    func testCorruptCacheRequiresExplicitReset() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("HealthLocal")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let file = local.appendingPathComponent("health_cache.v1.json")
        let bytes = Data("broken".utf8); try bytes.write(to: file)
        let client = MockHealthClient(); let reader = HealthReader(client: client, directory: directory)
        await reader.connect()
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertTrue(client.queries.isEmpty)
        reader.reset()
        await reader.connect()
        XCTAssertEqual(client.queries.count, 3)
    }
    func testXMLImportIsRepeatableAndFailedImportIsAtomic() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("export.xml")
        let now = Date()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let date = formatter.string(from: now.addingTimeInterval(-60))
        try Data("<HealthData><Record type='HKQuantityTypeIdentifierBodyMass' sourceName='Test' unit='kg' value='70' startDate='\(date)' endDate='\(date)'/></HealthData>".utf8).write(to: source)
        let store = HealthImportStore(directory: directory)
        await store.importFile(source, now: now)
        await store.importFile(source, now: now)
        XCTAssertEqual(store.records.count, 1)
        let file = directory.appendingPathComponent("HealthLocal/health_import.v1.json")
        let saved = try Data(contentsOf: file)
        try Data("<broken>".utf8).write(to: source)
        await store.importFile(source, now: now)
        XCTAssertEqual(try Data(contentsOf: file), saved)
        XCTAssertEqual(HealthImportStore(directory: directory).records.count, 1)
    }
    func testEmptyReadPreservesCachedValueAndDoesNotClaimNewMeasurement() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockHealthClient(); let now = Date()
        client.values[.pulse] = HealthRecord(id: "hk:test-pulse", field: .pulse, value: 60, start: now, end: now, source: "Test")
        let reader = HealthReader(client: client, directory: directory)
        await reader.connect(now: now)
        client.values = [:]
        await reader.refresh(force: true, now: now.addingTimeInterval(300))
        let pulse = try XCTUnwrap(reader.cache.snapshots.first { $0.field == .pulse })
        XCTAssertEqual(pulse.record?.value, 60)
        XCTAssertEqual(pulse.status, .empty)
        XCTAssertEqual(pulse.newDataAt, now)
    }
}
