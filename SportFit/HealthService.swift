import Foundation
import SwiftUI
#if SPORTFIT_HEALTHKIT
import HealthKit
#endif

@MainActor protocol HealthQueryClient {
    var buildEnabled: Bool { get }
    var available: Bool { get }
    func authorize() async throws
    func read(_ field: HealthField, now: Date) async throws -> HealthRecord?
}

@MainActor final class DeviceHealthClient: HealthQueryClient {
#if SPORTFIT_HEALTHKIT
    let buildEnabled = true
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    private let store = HKHealthStore()
    private func type(_ field: HealthField) -> HKQuantityType {
        HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: field.rawValue))!
    }
    private func unit(_ field: HealthField) -> HKUnit {
        switch field {
        case .weight: return .gramUnit(with: .kilo)
        case .steps: return .count()
        case .pulse: return HKUnit.count().unitDivided(by: .minute())
        }
    }
    func authorize() async throws {
        let types = Set(HealthField.allCases.map { type($0) as HKObjectType })
        try await store.requestAuthorization(toShare: [], read: types)
    }
    private func latest(type: HKQuantityType, predicate: NSPredicate) async throws -> HKQuantitySample? {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples?.first as? HKQuantitySample) }
            }
            store.execute(query)
        }
    }
    func read(_ field: HealthField, now: Date) async throws -> HealthRecord? {
        let type = type(field)
        let start = field == .steps ? SportDate.calendar.startOfDay(for: now) : nil
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictEndDate)
        if field == .steps {
            let summary: (Double?, [String]) = try await withCheckedThrowingContinuation { continuation in
                let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (result?.sumQuantity()?.doubleValue(for: .count()), result?.sources?.map(\.name).sorted() ?? [])) }
                }
                store.execute(query)
            }
            guard let total = summary.0 else { return nil }
            let last = try await latest(type: type, predicate: predicate)
            guard let last else { return nil }
            let day = SportDate.key(now)
            let zone = TimeZone.current.identifier
            return HealthRecord(id: "hk:steps:\(day):\(zone)", field: field, value: total, start: start!, end: last.endDate,
                source: "Apple Health · суточная статистика · " + summary.1.joined(separator: ", "), day: day, timeZone: zone)
        }
        guard let sample = try await latest(type: type, predicate: predicate) else { return nil }
        return HealthRecord(id: "hk:" + sample.uuid.uuidString, field: field, value: sample.quantity.doubleValue(for: unit(field)),
                            start: sample.startDate, end: sample.endDate, source: sample.sourceRevision.source.name,
                            sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier)
    }
#else
    let buildEnabled = false
    let available = false
    func authorize() async throws { throw DataValidation.Failure(message: "Эта сборка без HealthKit") }
    func read(_ field: HealthField, now: Date) async throws -> HealthRecord? { nil }
#endif
}

/// Health caches are local, protected and excluded from automatic device backups.
/// They deliberately do not participate in SportFit's workout backup format.
enum PrivateHealthFile {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options = URLResourceValues()
        options.isExcludedFromBackup = true
        var parent = url.deletingLastPathComponent()
        try parent.setResourceValues(options)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        var location = url
        try location.setResourceValues(options)
    }
}

@MainActor final class HealthReader: ObservableObject {
    @Published private(set) var cache = HealthCache()
    @Published private(set) var loading = false
    @Published var message = ""
    private var storageHealthy = true
    private let client: HealthQueryClient
    private let file: URL
    var buildEnabled: Bool { client.buildEnabled }
    var available: Bool { client.available }
    init(client: HealthQueryClient? = nil, directory: URL = LocalFiles.directory) {
        self.client = client ?? DeviceHealthClient()
        file = directory.appendingPathComponent("HealthLocal/health_cache.v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let loaded = try JSONDecoder().decode(HealthCache.self, from: Data(contentsOf: file))
                try loaded.validate()
                cache = loaded
            } catch { storageHealthy = false; message = "Кэш не прочитан. Очисти только локальный кэш, затем подключись заново. Данные Apple Health не изменяются." }
        }
    }
    func connect(now: Date = Date()) async { await perform(force: true, requestAuthorization: true, now: now) }
    func refresh(force: Bool = false, now: Date = Date()) async { await perform(force: force, requestAuthorization: false, now: now) }
    private func perform(force: Bool, requestAuthorization: Bool, now: Date) async {
        guard !loading, storageHealthy else { return }
        guard buildEnabled else { message = "Эта IPA без HealthKit. Доступен локальный импорт export.xml и ручной ввод."; return }
        guard available else { message = "Apple Health недоступен на этом устройстве"; return }
        guard requestAuthorization || (cache.connectionRequested && cache.shouldRefresh(now: now, force: force)) else { return }
        loading = true
        defer { loading = false }
        if requestAuthorization {
            do {
                try await client.authorize()
                cache.connectionRequested = true // Request completion, not proof of read permission.
            } catch { message = "Запрос доступа не выполнен: \(error.localizedDescription)"; return }
        }
        cache.lastAttempt = now
        cache.lastTimeZone = TimeZone.current.identifier
        for field in HealthField.allCases {
            guard let index = cache.snapshots.firstIndex(where: { $0.field == field }) else { continue }
            do {
                let record = try await client.read(field, now: now)
                try DataValidation.require(record.map { $0.valid && $0.field == field } ?? true, "Некорректный ответ Apple Health")
                cache.snapshots[index].received(record, now: now)
            } catch { cache.snapshots[index].failed(error.localizedDescription, now: now) }
        }
        message = "Проверка завершена. Пустой ответ не позволяет отличить отсутствие данных от запрета чтения. Новые значения появляются после записи Huawei Health в Apple Health."
        do { try PrivateHealthFile.write(cache, to: file) }
        catch { message = "Проверка выполнена, но кэш не сохранён: \(error.localizedDescription)" }
    }
    func reset() {
        guard !loading else { return }
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            cache = HealthCache()
            storageHealthy = true
            message = "Локальный кэш очищен. Записи Apple Health и ручные замеры сохранены."
        } catch { message = error.localizedDescription }
    }
}

@MainActor final class HealthImportStore: ObservableObject {
    @Published private(set) var records: [HealthRecord] = []
    @Published private(set) var importing = false
    @Published var message = ""
    private let file: URL
    private var storageHealthy = true
    init(directory: URL = LocalFiles.directory) {
        file = directory.appendingPathComponent("HealthLocal/health_import.v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let loaded = try JSONDecoder().decode([HealthRecord].self, from: Data(contentsOf: file))
                records = try HealthImportSummary.merged([], loaded)
            } catch { storageHealthy = false; message = "Файл импорта повреждён; он не перезаписывается. Очисти импорт и выбери исходный export.xml заново." }
        }
    }
    func importFile(_ url: URL, now: Date = Date()) async {
        guard !importing, storageHealthy else { return }
        importing = true
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            try DataValidation.require((values.fileSize ?? Int.max) <= 512 * 1024 * 1024, "export.xml превышает 512 МБ; нужен меньший локальный файл")
            // Parsing large exports must not block the main thread.
            let existing = records
            let destination = file
            let merged = try await Task.detached(priority: .userInitiated) {
                guard let stream = InputStream(url: url) else { throw DataValidation.Failure(message: "Файл не открыт") }
                let imported = try AppleHealthExport.parse(stream: stream, now: now)
                let updated = try HealthImportSummary.merged(existing, imported)
                try PrivateHealthFile.write(updated, to: destination)
                return updated
            }.value
            let added = merged.count - records.count
            records = merged
            message = "Добавлено записей: \(added). Читаются только вес, шаги и пульс за последние 90 дней. Повторы не добавляются. Это импорт файла, не прямая синхронизация."
        } catch { message = "Импорт не выполнен: \(error.localizedDescription)" }
    }
    func reset() {
        guard !importing else { return }
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            records = []; storageHealthy = true; message = "Импорт очищен. Исходный XML и ручные измерения сохранены."
        } catch { message = error.localizedDescription }
    }
}
