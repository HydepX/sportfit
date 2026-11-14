import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum HealthField: String, Codable, CaseIterable, Identifiable {
    case weight = "HKQuantityTypeIdentifierBodyMass"
    case steps = "HKQuantityTypeIdentifierStepCount"
    case pulse = "HKQuantityTypeIdentifierHeartRate"
    var id: String { rawValue }
    var title: String {
        switch self { case .weight: return "Вес"; case .steps: return "Шаги сегодня"; case .pulse: return "Пульс" }
    }
    var unit: String {
        switch self { case .weight: return "кг"; case .steps: return "шагов"; case .pulse: return "уд/мин" }
    }
}

struct HealthRecord: Codable, Equatable, Identifiable {
    let id: String
    let field: HealthField
    let value: Double
    let start: Date
    let end: Date
    let source: String
    var day: String? = nil
    var timeZone: String? = nil
    var sourceBundleIdentifier: String? = nil

    var valid: Bool {
        !id.isEmpty && !source.isEmpty && value.isFinite && value >= 0 && start <= end &&
        (field != .weight || value > 0) && (field != .pulse || value > 0) &&
        (field != .steps || value <= Double(Int.max))
    }
    static func imported(field: HealthField, value: Double, start: Date, end: Date, source: String) -> HealthRecord {
        // Apple export has no sample UUID. Use a stable, unit-normalized natural key.
        let parts = [field.rawValue, source, String(start.timeIntervalSince1970), String(end.timeIntervalSince1970), String(value)]
        let key = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return HealthRecord(id: "xml:" + key, field: field, value: value, start: start, end: end, source: source)
    }
}

enum HealthQueryStatus: String, Codable { case notChecked, readable, empty, failed }
struct HealthSnapshot: Codable {
    var field: HealthField
    var record: HealthRecord?
    var status: HealthQueryStatus = .notChecked
    var checkedAt: Date?
    var successfulQueryAt: Date?
    var newDataAt: Date?
    var error: String?
    mutating func received(_ record: HealthRecord?, now: Date) {
        checkedAt = now
        successfulQueryAt = now
        error = nil
        status = record == nil ? .empty : .readable
        if let record {
            if self.record != record { newDataAt = now }
            self.record = record
        }
        // Empty/denied results never erase the last known value or invent zero.
    }
    mutating func failed(_ error: String, now: Date) {
        checkedAt = now
        status = .failed
        self.error = error
    }
    func isOld(now: Date = Date()) -> Bool {
        guard let record else { return true }
        switch field {
        case .weight: return now.timeIntervalSince(record.end) > 7 * 86400
        case .pulse: return now.timeIntervalSince(record.end) > 86400
        case .steps: return record.day != SportDate.key(now) || record.timeZone != TimeZone.current.identifier
        }
    }
}

struct HealthCache: Codable {
    var format = "sportfit-health-cache-v1"
    var connectionRequested = false
    var snapshots: [HealthSnapshot] = HealthField.allCases.map { HealthSnapshot(field: $0) }
    var lastAttempt: Date?
    var lastTimeZone: String?
    func shouldRefresh(now: Date, force: Bool) -> Bool {
        guard connectionRequested || force else { return false }
        return force || lastAttempt == nil || now.timeIntervalSince(lastAttempt!) >= 300 ||
            SportDate.key(lastAttempt!) != SportDate.key(now) || lastTimeZone != TimeZone.current.identifier
    }
    func validate() throws {
        try DataValidation.require(format == "sportfit-health-cache-v1" && Set(snapshots.map(\.field)) == Set(HealthField.allCases) &&
            snapshots.count == HealthField.allCases.count && snapshots.allSatisfy { $0.record?.valid ?? true },
            "Повреждён локальный кэш Apple Health")
        for snapshot in snapshots {
            try DataValidation.require(snapshot.record.map { $0.field == snapshot.field } ?? true, "Перепутаны показатели Apple Health")
        }
    }
}

enum HealthImportSummary {
    static func latest(_ field: HealthField, records: [HealthRecord]) -> HealthRecord? {
        records.filter { $0.field == field }.max { $0.end < $1.end }
    }
    static func steps(records: [HealthRecord], source: String, day: Date, calendar: Calendar = SportDate.calendar) throws -> Double? {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let relevant = records.filter { $0.field == .steps && $0.source == source && $0.start < end &&
            ($0.end > start || ($0.start == $0.end && $0.start >= start)) }
        try DataValidation.require(relevant.allSatisfy { $0.start >= start && $0.end <= end },
                                   "В файле есть шаги через полночь: точный итог за день недоступен")
        let unique = Dictionary(relevant.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.start < $1.start }
        guard !unique.isEmpty else { return nil }
        var previous: HealthRecord?
        for item in unique {
            if let previous {
                try DataValidation.require(item.start >= previous.end && item.start != previous.start,
                                           "Интервалы шагов одного источника пересекаются; итог не суммируется")
            }
            previous = item
        }
        let total = unique.reduce(0) { $0 + $1.value }
        try DataValidation.require(total.isFinite && total <= Double(Int.max), "Некорректный итог шагов")
        return total
    }
    static func merged(_ old: [HealthRecord], _ imported: [HealthRecord]) throws -> [HealthRecord] {
        try DataValidation.require((old + imported).allSatisfy(\.valid), "Некорректные данные импорта")
        var known = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in imported { known[record.id] = record }
        try DataValidation.require(known.count <= 200_000, "Слишком много записей; импортируй меньший период")
        return known.values.sorted { $0.end < $1.end }
    }
}

/// Streaming on-device parser. Never resolves external entities or sends an export anywhere.
final class AppleHealthExport: NSObject, XMLParserDelegate {
    private var records: [String: HealthRecord] = [:]
    private var failure: Error?
    private var rootSeen = false
    private var now = Date()
    private var earliest = Date()
    private let dateFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return value
    }()
    static func parse(stream: InputStream, now: Date = Date()) throws -> [HealthRecord] {
        let delegate = AppleHealthExport()
        delegate.now = now
        delegate.earliest = now.addingTimeInterval(-90 * 86400)
        let parser = XMLParser(stream: stream)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil, delegate.rootSeen else {
            throw delegate.failure ?? DataValidation.Failure(message: "Не удалось прочитать export.xml Apple Health")
        }
        return delegate.records.values.sorted { $0.end < $1.end }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if !rootSeen {
            guard name == "HealthData" else { fail(parser, "Нужен export.xml Apple Health"); return }
            rootSeen = true
        }
        guard name == "Record", let type = attributes["type"], let field = HealthField(rawValue: type) else { return }
        guard let endString = attributes["endDate"], let end = dateFormatter.date(from: endString) else { fail(parser, "Некорректная дата измерения"); return }
        guard end <= now, end >= earliest else { return }
        guard let startString = attributes["startDate"], let start = dateFormatter.date(from: startString),
              let text = attributes["value"], let raw = Double(text), let source = attributes["sourceName"],
              let unit = attributes["unit"] else { fail(parser, "Неполная запись измерения"); return }
        let value: Double
        switch (field, unit) {
        case (.weight, "kg"): value = raw
        case (.weight, "g"): value = raw / 1000
        case (.weight, "lb"): value = raw * 0.45359237
        case (.steps, "count"), (.pulse, "count/min"): value = raw
        default: fail(parser, "Неподдерживаемая единица измерения"); return
        }
        let record = HealthRecord.imported(field: field, value: value, start: start, end: end, source: source)
        guard record.valid else { fail(parser, "Некорректное значение измерения"); return }
        records[record.id] = record
        if records.count > 200_000 { fail(parser, "В файле более 200000 записей за 90 дней") }
    }
    private func fail(_ parser: XMLParser, _ message: String) { failure = DataValidation.Failure(message: message); parser.abortParsing() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { fail(parser, "XML-сущности не поддерживаются") }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(parser, "Внешние XML-сущности запрещены") }
}
