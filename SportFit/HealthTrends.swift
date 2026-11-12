import SwiftUI
import Charts
#if SPORTFIT_HEALTHKIT
import HealthKit
#endif

enum HealthMetric: String, CaseIterable, Identifiable {
    case weight = "Вес", bmi = "ИМТ", fat = "Жир", steps = "Шаги", distance = "Расстояние"
    case calories = "Активные калории", pulse = "Пульс", restingPulse = "Пульс в покое", oxygen = "SpO₂", sleep = "Сон"
    var id: String { rawValue }
    var unitLabel: String {
        switch self {
        case .weight: return "кг"
        case .bmi: return "ИМТ"
        case .fat, .oxygen: return "%"
        case .steps: return "шагов"
        case .distance: return "км"
        case .calories: return "ккал"
        case .pulse, .restingPulse: return "уд/мин"
        case .sleep: return "мин"
        }
    }
#if SPORTFIT_HEALTHKIT
    var quantityIdentifier: HKQuantityTypeIdentifier? {
        switch self {
        case .weight: return .bodyMass
        case .bmi: return .bodyMassIndex
        case .fat: return .bodyFatPercentage
        case .steps: return .stepCount
        case .distance: return .distanceWalkingRunning
        case .calories: return .activeEnergyBurned
        case .pulse: return .heartRate
        case .restingPulse: return .restingHeartRate
        case .oxygen: return .oxygenSaturation
        case .sleep: return nil
        }
    }
    var unit: HKUnit {
        switch self {
        case .weight: return .gramUnit(with: .kilo)
        case .bmi, .steps: return .count()
        case .fat, .oxygen: return .percent()
        case .distance: return .meterUnit(with: .kilo)
        case .calories: return .kilocalorie()
        case .pulse, .restingPulse: return HKUnit.count().unitDivided(by: .minute())
        case .sleep: return .minute()
        }
    }
    var isCumulative: Bool { [.steps, .distance, .calories].contains(self) }
#endif
}

struct HealthTrendPoint: Identifiable {
    let id: UUID
    let date: Date
    let value: Double
    let source: String
}

@MainActor final class HealthTrends: ObservableObject {
    @Published var points: [HealthTrendPoint] = []
    @Published var message = ""
    @Published var loading = false
#if SPORTFIT_HEALTHKIT
    private let store = HKHealthStore()
#endif
    func load(metric: HealthMetric, period: AnalyticsPeriod, requestAccess: Bool = false) async {
        guard !loading else { return }
        loading = true
        points = []
        defer { loading = false }
#if SPORTFIT_HEALTHKIT
        guard HKHealthStore.isHealthDataAvailable() else { message = "Apple Health недоступен"; return }
        let component: Calendar.Component
        let amount: Int
        switch period {
        case .week: component = .day; amount = -7
        case .month: component = .month; amount = -1
        case .quarter: component = .month; amount = -3
        case .year: component = .year; amount = -1
        case .all: component = .year; amount = -100
        }
        let now = Date()
        let start = SportDate.calendar.date(byAdding: component, value: amount, to: now) ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
        do {
            if metric == .sleep {
                guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return }
                if requestAccess { try await store.requestAuthorization(toShare: [], read: [type]) }
                let samples = try await query(type: type, predicate: predicate)
                let asleep = samples.compactMap { $0 as? HKCategorySample }.filter { [1, 3, 4, 5].contains($0.value) }
                // Split intervals at local midnight, then merge overlaps from stages/sources.
                var days: [Date: [(Date, Date)]] = [:]
                for sample in asleep {
                    var cursor = max(sample.startDate, start)
                    let end = min(sample.endDate, now)
                    while cursor < end {
                        let day = SportDate.calendar.startOfDay(for: cursor)
                        guard let next = SportDate.calendar.date(byAdding: .day, value: 1, to: day) else { break }
                        let stop = min(end, next)
                        days[day, default: []].append((cursor, stop))
                        cursor = stop
                    }
                }
                for (day, intervals) in days {
                    var merged: (Date, Date)?
                    var seconds: TimeInterval = 0
                    for item in intervals.sorted(by: { $0.0 < $1.0 }) {
                        if let prior = merged, item.0 <= prior.1 { merged = (prior.0, max(prior.1, item.1)) }
                        else {
                            if let prior = merged { seconds += prior.1.timeIntervalSince(prior.0) }
                            merged = item
                        }
                    }
                    if let prior = merged { seconds += prior.1.timeIntervalSince(prior.0) }
                    points.append(HealthTrendPoint(id: UUID(), date: day, value: seconds / 60,
                                                  source: "Apple Health · объединённый сон"))
                }
            } else if let id = metric.quantityIdentifier, let type = HKQuantityType.quantityType(forIdentifier: id) {
                if requestAccess { try await store.requestAuthorization(toShare: [], read: [type]) }
                if metric.isCumulative {
                    points = try await withCheckedThrowingContinuation { continuation in
                        let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                            options: .cumulativeSum, anchorDate: SportDate.calendar.startOfDay(for: now),
                            intervalComponents: DateComponents(day: 1))
                        let queryStore = store
                        query.initialResultsHandler = { query, collection, error in
                            queryStore.stop(query)
                            if let error { continuation.resume(throwing: error); return }
                            var values: [HealthTrendPoint] = []
                            collection?.enumerateStatistics(from: start, to: now) { statistics, _ in
                                if let quantity = statistics.sumQuantity() {
                                    values.append(HealthTrendPoint(id: UUID(), date: statistics.startDate,
                                        value: quantity.doubleValue(for: metric.unit), source: "Apple Health · суточный итог"))
                                }
                            }
                            continuation.resume(returning: values)
                        }
                        store.execute(query)
                    }
                } else {
                    let samples = try await query(type: type, predicate: predicate)
                    points = samples.compactMap { sample in
                        guard let quantity = sample as? HKQuantitySample else { return nil }
                        return HealthTrendPoint(id: quantity.uuid, date: quantity.endDate,
                            value: quantity.quantity.doubleValue(for: metric.unit) * ([HealthMetric.fat, .oxygen].contains(metric) ? 100 : 1),
                            source: quantity.sourceRevision.source.name)
                    }
                }
            }
            points.sort { $0.date < $1.date }
            message = "Показаны доступные записи Apple Health. Для отдельных измерений и сна — не более последних 5000 записей. Пустой результат не различает отсутствие данных и запрет чтения."
        } catch { message = error.localizedDescription }
#else
        message = "Эта IPA не включает HealthKit. Ручные графики доступны в разделе замеров; импорт измерений — в профиле."
#endif
    }
#if SPORTFIT_HEALTHKIT
    private func query(type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 5000,
                                     sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }
#endif
}

struct HealthTrendsScreen: View {
    @StateObject private var store = HealthTrends()
    @State private var metric = HealthMetric.weight
    @State private var period = AnalyticsPeriod.month
    var body: some View {
        List {
            Picker("Показатель", selection: $metric) {
                ForEach(HealthMetric.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(store.loading)
            Picker("Период", selection: $period) {
                ForEach(AnalyticsPeriod.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(store.loading)
            Button("Подключить показатель и обновить") { Task { await store.load(metric: metric, period: period, requestAccess: true) } }.disabled(store.loading)
            if store.loading { ProgressView() }
            if store.points.count >= 2 {
                Chart(store.points) { point in
                    LineMark(x: .value("Дата", point.date), y: .value(metric.unitLabel, point.value))
                        .foregroundStyle(by: .value("Источник", point.source))
                }.frame(height: 220)
            } else { Text("Недостаточно доступных данных для графика") }
            Text(store.message).font(.footnote)
            ForEach(store.points.reversed()) { point in
                VStack(alignment: .leading) {
                    Text("\(point.value.formatted()) \(metric.unitLabel)")
                    Text("\(point.date.formatted()) · \(point.source)").font(.caption)
                }
            }
        }.navigationTitle("Динамика Apple Health")
            .task { await store.load(metric: metric, period: period) }
            .onChange(of: metric) { _, _ in Task { await store.load(metric: metric, period: period) } }
            .onChange(of: period) { _, _ in Task { await store.load(metric: metric, period: period) } }
    }
}
