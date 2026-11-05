import SwiftUI
#if SPORTFIT_HEALTHKIT
import HealthKit
#endif

struct HealthReading: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let date: Date
    let source: String
}

@MainActor final class HealthReader: ObservableObject {
    @Published var readings: [HealthReading] = []
    @Published var status = ""
    @Published var loading = false
#if SPORTFIT_HEALTHKIT
    private let store = HKHealthStore()
    private let quantities: [(HKQuantityTypeIdentifier, String, HKUnit, Bool)] = [
        (.bodyMass, "Вес", .gramUnit(with: .kilo), false),
        (.bodyMassIndex, "ИМТ", .count(), false),
        (.bodyFatPercentage, "Жир", .percent(), false),
        (.stepCount, "Шаги сегодня", .count(), true),
        (.distanceWalkingRunning, "Расстояние сегодня", .meterUnit(with: .kilo), true),
        (.activeEnergyBurned, "Активные калории сегодня", .kilocalorie(), true),
        (.heartRate, "Пульс", HKUnit.count().unitDivided(by: .minute()), false),
        (.restingHeartRate, "Пульс в покое", HKUnit.count().unitDivided(by: .minute()), false),
        (.oxygenSaturation, "SpO₂", .percent(), false)
    ]
#endif
    func read() async {
#if SPORTFIT_HEALTHKIT
        guard HKHealthStore.isHealthDataAvailable() else { status = "Apple Health недоступен на этом устройстве"; return }
        loading = true
        defer { loading = false }
        do {
            var types = Set(quantities.compactMap { HKQuantityType.quantityType(forIdentifier: $0.0) }.map { $0 as HKObjectType })
            if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
            try await store.requestAuthorization(toShare: [], read: types)
            readings = []
            for (id, title, unit, daily) in quantities {
                guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
                let predicate = daily ? HKQuery.predicateForSamples(withStart: SportDate.calendar.startOfDay(for: Date()), end: Date()) : nil
                if daily {
                    let value: Double? = await withCheckedContinuation { continuation in
                        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, _ in
                            continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: unit))
                        }
                        store.execute(query)
                    }
                    if let value {
                        readings.append(HealthReading(title: title, value: "\(value.formatted()) \(unit.unitString)", date: Date(), source: "Apple Health · сводные данные"))
                    }
                } else {
                    let samples = await samples(type: type, predicate: nil, limit: 1)
                    if let sample = samples.first as? HKQuantitySample {
                        let value = sample.quantity.doubleValue(for: unit) * (unit == .percent() ? 100 : 1)
                        readings.append(HealthReading(title: title, value: "\(value.formatted()) \(unit.unitString)", date: sample.endDate, source: sample.sourceRevision.source.name))
                    }
                }
            }
            if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
                let from = SportDate.calendar.date(byAdding: .day, value: -1, to: Date())!
                let samples = await samples(type: sleep, predicate: HKQuery.predicateForSamples(withStart: from, end: Date()), limit: HKObjectQueryNoLimit)
                let intervals = samples.compactMap { $0 as? HKCategorySample }
                    .filter { [1, 3, 4, 5].contains($0.value) }
                    .map { (max($0.startDate, from), min($0.endDate, Date())) }.sorted { $0.0 < $1.0 }
                // Merge overlapping stages/sources instead of counting sleep twice.
                var total: TimeInterval = 0
                var merged: (Date, Date)?
                for interval in intervals where interval.1 > interval.0 {
                    if let old = merged, interval.0 <= old.1 { merged = (old.0, max(old.1, interval.1)) }
                    else {
                        if let old = merged { total += old.1.timeIntervalSince(old.0) }
                        merged = interval
                    }
                }
                if let old = merged { total += old.1.timeIntervalSince(old.0) }
                if total > 0 { readings.append(HealthReading(title: "Сон за 24 часа", value: "\(Int(total / 60)) мин", date: Date(), source: "Apple Health · объединённые интервалы")) }
            }
            status = "Пустой список означает отсутствие доступных записей или доступа. HealthKit не раскрывает отказ в чтении. Huawei может передавать только часть категорий."
        } catch { status = "Не удалось прочитать Apple Health: \(error.localizedDescription)" }
#else
        status = "В этой сборке HealthKit отключён для совместимости с бесплатной подписью. Используй ручные замеры или импорт JSON. Доступ HealthKit через AltStore на этом iPhone ещё не подтверждён."
#endif
    }
#if SPORTFIT_HEALTHKIT
    private func samples(type: HKSampleType, predicate: NSPredicate?, limit: Int) async -> [HKSample] {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, _ in
                continuation.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }
#endif
}

struct HealthScreen: View {
    @StateObject private var reader = HealthReader()
    var body: some View {
        List {
            Text("HUAWEI WATCH FIT 2 и Body Fat Scale 3 → Huawei Health → Apple Health. Прямое подключение к Huawei не используется.")
            Button("Запросить доступ и обновить") { Task { await reader.read() } }.disabled(reader.loading)
            if reader.loading { ProgressView() }
            Text(reader.status)
            ForEach(reader.readings) { item in
                VStack(alignment: .leading) {
                    Text(item.title).font(.headline)
                    Text(item.value)
                    Text("\(item.source) · \(item.date.formatted())").font(.caption)
                }
            }
            NavigationLink("Динамика показателей Apple Health") { HealthTrendsScreen() }
            NavigationLink("Ручные измерения") { MeasurementsScreen() }
            Text("Данные читаются локально и не отправляются на сервер. Автоматические показатели показываются отдельно от ручных измерений.")
        }.navigationTitle("Apple Health").task { await reader.read() }
    }
}
