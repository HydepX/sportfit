import XCTest
@testable import SportFitCore

final class HealthDataTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_484_800)
    private func record(_ field: HealthField = .weight, value: Double = 70, source: String = "Test", start: Date? = nil, end: Date? = nil) -> HealthRecord {
        HealthRecord.imported(field: field, value: value, start: start ?? now, end: end ?? now, source: source)
    }
    private func parse(_ body: String) throws -> [HealthRecord] {
        try AppleHealthExport.parse(stream: InputStream(data: Data(body.utf8)), now: Date(timeIntervalSince1970: 1_794_528_000))
    }
    private func xml(_ field: HealthField, value: String, unit: String) -> String {
        "<Record type=\"\(field.rawValue)\" sourceName=\"Test\" unit=\"\(unit)\" value=\"\(value)\" startDate=\"2026-11-12 10:00:00 +0000\" endDate=\"2026-11-12 10:00:00 +0000\"/>"
    }
    func testThreeCategoriesParseAndRepeatedExportDeduplicates() throws {
        let content = "<HealthData>" + xml(.weight, value: "70", unit: "kg") + xml(.steps, value: "100", unit: "count") + xml(.pulse, value: "60", unit: "count/min") + "</HealthData>"
        let records = try parse(content)
        XCTAssertEqual(Set(records.map(\.field)), Set(HealthField.allCases))
        XCTAssertEqual(try HealthImportSummary.merged(records, try parse(content)).count, 3)
    }
    func testUnitNormalizationDoesNotMakeDuplicateWeights() throws {
        let records = try parse("<HealthData>" + xml(.weight, value: "1", unit: "kg") + xml(.weight, value: "1000", unit: "g") + "</HealthData>")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.value, 1)
    }
    func testInvalidUnitsAndEntitiesAreRejected() throws {
        XCTAssertThrowsError(try parse("<HealthData>" + xml(.pulse, value: "60", unit: "kg") + "</HealthData>"))
        XCTAssertThrowsError(try parse("<!DOCTYPE HealthData [<!ENTITY x 'test'>]><HealthData>&x;</HealthData>"))
        XCTAssertThrowsError(try parse("<WrongRoot/>"))
    }
    func testUnsupportedCategoriesAreNotImported() throws {
        XCTAssertTrue(try parse("<HealthData><Record type='HKQuantityTypeIdentifierBloodGlucose' value='5'/></HealthData>").isEmpty)
    }
    func testEmptyQueryRetainsLastKnownValueButNotReadableStatus() {
        var snapshot = HealthSnapshot(field: .weight)
        snapshot.received(record(), now: now)
        snapshot.received(nil, now: now.addingTimeInterval(300))
        XCTAssertEqual(snapshot.record?.value, 70)
        XCTAssertEqual(snapshot.status, .empty)
        XCTAssertEqual(snapshot.newDataAt, now)
        XCTAssertNotEqual(snapshot.successfulQueryAt, snapshot.newDataAt)
    }
    func testErrorDoesNotBecomeZeroOrSuccessfulRead() {
        var snapshot = HealthSnapshot(field: .weight)
        snapshot.received(record(), now: now)
        snapshot.failed("Test error", now: now.addingTimeInterval(300))
        XCTAssertEqual(snapshot.record?.value, 70)
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertEqual(snapshot.successfulQueryAt, now)
    }
    func testUnchangedReadDoesNotPretendThereIsNewData() {
        var snapshot = HealthSnapshot(field: .pulse)
        let value = record(.pulse, value: 60)
        snapshot.received(value, now: now)
        snapshot.received(value, now: now.addingTimeInterval(300))
        XCTAssertEqual(snapshot.newDataAt, now)
        XCTAssertEqual(snapshot.status, .readable)
    }
    func testRefreshRequiresConnectionAndDebouncesFiveMinutes() {
        var cache = HealthCache()
        XCTAssertFalse(cache.shouldRefresh(now: now, force: false))
        cache.connectionRequested = true; cache.lastAttempt = now; cache.lastTimeZone = TimeZone.current.identifier
        XCTAssertFalse(cache.shouldRefresh(now: now.addingTimeInterval(299), force: false))
        XCTAssertTrue(cache.shouldRefresh(now: now.addingTimeInterval(300), force: false))
        XCTAssertTrue(cache.shouldRefresh(now: now, force: true))
        cache.lastTimeZone = "Different/Zone"
        XCTAssertTrue(cache.shouldRefresh(now: now, force: false))
    }
    func testStepsUseOneSourceAndNeverSumOverlappingIntervals() throws {
        let start = SportDate.calendar.startOfDay(for: now).addingTimeInterval(3600)
        let first = record(.steps, value: 10, source: "Watch", start: start, end: start.addingTimeInterval(60))
        let second = record(.steps, value: 20, source: "Phone", start: start, end: start.addingTimeInterval(60))
        XCTAssertEqual(try HealthImportSummary.steps(records: [first, first, second], source: "Watch", day: now), 10)
        let overlap = record(.steps, value: 30, source: "Watch", start: start.addingTimeInterval(30), end: start.addingTimeInterval(90))
        XCTAssertThrowsError(try HealthImportSummary.steps(records: [first, overlap], source: "Watch", day: now))
        XCTAssertNil(try HealthImportSummary.steps(records: [], source: "Watch", day: now))
    }
    func testMidnightIntervalsAreNotProportionallyInvented() throws {
        let start = SportDate.calendar.startOfDay(for: now)
        let crossing = record(.steps, value: 100, start: start.addingTimeInterval(-60), end: start.addingTimeInterval(60))
        XCTAssertThrowsError(try HealthImportSummary.steps(records: [crossing], source: "Test", day: now))
        var cached = HealthSnapshot(field: .steps)
        cached.received(HealthRecord(id: "day", field: .steps, value: 100, start: now, end: now,
            source: "Test", day: "old-day", timeZone: TimeZone.current.identifier), now: now)
        XCTAssertTrue(cached.isOld(now: now))
    }
}
