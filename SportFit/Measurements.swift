import SwiftUI
import Charts

@MainActor
final class MeasurementsStore: ObservableObject {
    @Published private(set) var entries: [BodyMeasurement] = []
    @Published var error: String?
    private var storageHealthy = true
    var canExport: Bool { storageHealthy && LocalFiles.recoveryError == nil }

    private var fileURL: URL {
        directory.appendingPathComponent("body_measurements.v1.json")
    }

    let directory: URL
    init(directory: URL = LocalFiles.directory) { self.directory = directory; reload() }

    func reload() {
        storageHealthy = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { entries = []; return }
        do {
            let values = try JSONDecoder().decode([BodyMeasurement].self, from: Data(contentsOf: fileURL))
            try DataValidation.require(values.allSatisfy(Self.valid), "Некорректные сохранённые измерения")
            entries = values.sorted { $0.measuredAt < $1.measuredAt }
        } catch {
            storageHealthy = false
            self.error = "Ошибка чтения измерений; исходный файл сохранён: \(error.localizedDescription)"
        }
    }

    var latest: BodyMeasurement? { entries.last }

    func update(_ entry: BodyMeasurement) -> Bool {
        guard Self.valid(entry) else { error = "Проверь значения измерений"; return false }
        let previous = entries
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry }
        else { entries.append(entry) }
        entries.sort { $0.measuredAt < $1.measuredAt }
        if !persist() { entries = previous; return false }
        return true
    }

    static func valid(_ entry: BodyMeasurement) -> Bool {
        entry.weightKg.isFinite && (20...400).contains(entry.weightKg) &&
        entry.measuredAt <= Date() &&
        [entry.waistCm, entry.chestCm, entry.hipsCm].allSatisfy { $0.map { $0.isFinite && (10...300).contains($0) } ?? true } &&
        (entry.bodyFatPercent.map { $0.isFinite && (1...75).contains($0) } ?? true) &&
        (entry.heightCm.map { $0.isFinite && (50...250).contains($0) } ?? true) &&
        (entry.muscleMassKg.map { $0.isFinite && (1...250).contains($0) } ?? true) &&
        !entry.source.isEmpty
    }

    func importFile(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let imported = try JSONDecoder().decode([BodyMeasurement].self, from: Data(contentsOf: url))
        try DataValidation.require(imported.allSatisfy(Self.valid) && Set(imported.map(\.id)).count == imported.count,
                                   "Некорректные измерения")
        let previous = entries
        let known = Set(entries.map(\.id))
        entries += imported.filter { !known.contains($0.id) }
        entries.sort { $0.measuredAt < $1.measuredAt }
        if !persist() { entries = previous; throw DataValidation.Failure(message: error ?? "Ошибка записи") }
    }

    func add(date: Date, weightKg: Double?, waistCm: Double?, bodyFatPercent: Double?) -> Bool {
        guard let weightKg, (20...400).contains(weightKg),
              waistCm == nil || (30...250).contains(waistCm!),
              bodyFatPercent == nil || (1...75).contains(bodyFatPercent!) else {
            error = "Проверь вес (20–400 кг), талию (30–250 см) и жир (1–75%)."
            return false
        }
        let previous = entries
        entries.append(BodyMeasurement(date: date, weightKg: weightKg, waistCm: waistCm,
                                       bodyFatPercent: bodyFatPercent))
        entries.sort { $0.measuredAt < $1.measuredAt }
        if !persist() { entries = previous; return false }
        return true
    }

    func delete(_ id: UUID) {
        let previous = entries
        entries.removeAll { $0.id == id }
        if !persist() { entries = previous }
    }

    @discardableResult
    private func persist() -> Bool {
        guard storageHealthy, LocalFiles.recoveryError == nil else {
            error = LocalFiles.recoveryError ?? "Восстанови измерения из копии перед изменением"
            return false
        }
        do {
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
            return true
        } catch {
            self.error = "Не удалось сохранить измерения: \(error.localizedDescription)"
            return false
        }
    }
}

enum MeasurementMetric: String, CaseIterable, Identifiable {
    case weight = "Вес, кг", waist = "Талия, см", chest = "Грудь, см", hips = "Бёдра, см"
    case fat = "Жир, %", muscle = "Мышцы, кг", bmi = "ИМТ"
    var id: String { rawValue }
    func value(_ entry: BodyMeasurement) -> Double? {
        switch self {
        case .weight: return entry.weightKg
        case .waist: return entry.waistCm
        case .chest: return entry.chestCm
        case .hips: return entry.hipsCm
        case .fat: return entry.bodyFatPercent
        case .muscle: return entry.muscleMassKg
        case .bmi: return entry.bmi
        }
    }
}

struct MeasurementsScreen: View {
    @EnvironmentObject private var store: MeasurementsStore
    @State private var showNew = false
    @State private var editing: BodyMeasurement?
    @State private var period = AnalyticsPeriod.all
    @State private var metric = MeasurementMetric.weight
    private var filtered: [BodyMeasurement] { store.entries.filter { period.contains($0.measuredAt) } }

    private func measurementDetails(_ entry: BodyMeasurement) -> String {
        var parts = [entry.source == "manual" ? "Вручную" : entry.source]
        if let value = entry.bmi { parts.append("ИМТ \(value.formatted(.number.precision(.fractionLength(1))))") }
        if let value = entry.chestCm { parts.append("грудь \(value) см") }
        if let value = entry.hipsCm { parts.append("бёдра \(value) см") }
        if let value = entry.muscleMassKg { parts.append("мышцы \(value) кг") }
        if let waist = entry.waistCm { parts.append("талия \(waist) см") }
        if let fat = entry.bodyFatPercent { parts.append("жир \(fat)%") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let latest = store.latest {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Последний вес").font(.subheadline).foregroundStyle(.secondary)
                        Text(latest.weightKg.formatted(.number.precision(.fractionLength(1))) + " кг")
                            .font(.system(size: 36, weight: .bold))
                        Text(latest.measuredAt, format: .dateTime.day().month(.wide).year())
                            .font(.footnote).foregroundStyle(.secondary)
                        if let fat = latest.bodyFatPercent {
                            Text("Жир: \(fat.formatted(.number.precision(.fractionLength(1))))%")
                        }
                        if let waist = latest.waistCm {
                            Text("Талия: \(waist.formatted(.number.precision(.fractionLength(1)))) см")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(.white.opacity(0.07),
                                              in: RoundedRectangle(cornerRadius: 19))
                } else {
                    ContentUnavailableView("Пока нет замеров",
                        systemImage: "scalemass",
                        description: Text("Добавь первое измерение. Данные сохраняются только на этом iPhone."))
                }

                Picker("Период", selection: $period) {
                    ForEach(AnalyticsPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Показатель", selection: $metric) {
                    ForEach(MeasurementMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                let values = filtered.compactMap { metric.value($0) }
                if let first = values.first, let last = values.last, values.count > 1 {
                    Text("Изменение: \((last - first).formatted(.number.precision(.fractionLength(1)))) · \(metric.rawValue)")
                } else { Text("Недостаточно измерений для сравнения").foregroundStyle(.secondary) }
                if filtered.count >= 2 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(metric.rawValue).font(.headline)
                        Chart(filtered) { entry in
                            if let value = metric.value(entry) {
                                LineMark(x: .value("Дата", entry.measuredAt), y: .value(metric.rawValue, value))
                                    .foregroundStyle(by: .value("Источник", entry.source))
                                PointMark(x: .value("Дата", entry.measuredAt), y: .value(metric.rawValue, value))
                                    .foregroundStyle(by: .value("Источник", entry.source))
                            }
                        }
                        .frame(height: 180)
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                    }.padding().background(.white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 19))
                }

                Button {
                    showNew = true
                } label: {
                    Label("Добавить измерение", systemImage: "plus")
                }.buttonStyle(SportPrimaryButton())

                Text("История измерений").font(.title3.bold())
                ForEach(filtered.reversed()) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.measuredAt, format: .dateTime.day().month().year())
                                .font(.headline)
                            Text(measurementDetails(entry))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(entry.weightKg.formatted(.number.precision(.fractionLength(1)))) кг")
                            .font(.headline)
                    }
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .contextMenu {
                        Button("Изменить") { editing = entry }
                        Button("Удалить запись", role: .destructive) { store.delete(entry.id) }
                    }
                }
                Text("Автоматические данные Apple Health подключим после проверки HealthKit. Пока используются только ручные измерения.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.086))
        .navigationTitle("Замеры")
        .sheet(isPresented: $showNew) { NewMeasurementSheet() }
        .sheet(item: $editing) { NewMeasurementSheet(entry: $0) }
        .alert("SportFit", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("Понятно") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

private struct NewMeasurementSheet: View {
    @EnvironmentObject private var store: MeasurementsStore
    @Environment(\.dismiss) private var dismiss
    var entry: BodyMeasurement? = nil
    @State private var height = ""
    @State private var chest = ""
    @State private var hips = ""
    @State private var muscle = ""
    @State private var measuredAt = Date()
    @State private var weight = ""
    @State private var waist = ""
    @State private var fat = ""

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Дата", selection: $measuredAt, in: ...Date(), displayedComponents: .date)
                Section("Параметры") {
                    LabeledContent("Вес, кг") {
                        TextField("Например, 97.0", text: $weight)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Талия, см") {
                        TextField("Необязательно", text: $waist)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Жир, %") {
                        TextField("Необязательно", text: $fat)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                Section("Дополнительно") {
                    TextField("Рост, см", text: $height).keyboardType(.decimalPad)
                    TextField("Грудь, см", text: $chest).keyboardType(.decimalPad)
                    TextField("Бёдра, см", text: $hips).keyboardType(.decimalPad)
                    TextField("Мышечная масса, кг", text: $muscle).keyboardType(.decimalPad)
                }
                Text("Показатели состава тела с биоимпедансных весов ориентировочные; важнее наблюдать изменения во времени.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .onAppear {
                guard let entry else { return }
                measuredAt = entry.measuredAt
                weight = String(entry.weightKg)
                waist = entry.waistCm.map { String($0) } ?? ""
                fat = entry.bodyFatPercent.map { String($0) } ?? ""
                height = entry.heightCm.map { String($0) } ?? ""
                chest = entry.chestCm.map { String($0) } ?? ""
                hips = entry.hipsCm.map { String($0) } ?? ""
                muscle = entry.muscleMassKg.map { String($0) } ?? ""
            }
            .navigationTitle(entry == nil ? "Новое измерение" : "Изменить измерение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") {
                        func value(_ text: String) -> Double? {
                            Double(text.replacingOccurrences(of: ",", with: "."))
                        }
                        let waistValue = waist.isEmpty ? nil : value(waist)
                        let fatValue = fat.isEmpty ? nil : value(fat)
                        guard (waist.isEmpty || waistValue != nil),
                              (fat.isEmpty || fatValue != nil) else {
                            store.error = "Введи числовые значения для талии и процента жира."
                            return
                        }
                        let optionalValues = [height, chest, hips, muscle]
                        guard optionalValues.allSatisfy({ $0.isEmpty || value($0) != nil }), let weightValue = value(weight) else {
                            store.error = "Введи числовые значения"; return
                        }
                        var updated = entry ?? BodyMeasurement(date: measuredAt, weightKg: weightValue,
                                                               waistCm: waistValue, bodyFatPercent: fatValue)
                        updated.measuredAt = measuredAt
                        updated.weightKg = weightValue
                        updated.waistCm = waistValue
                        updated.bodyFatPercent = fatValue
                        updated.heightCm = value(height)
                        updated.chestCm = value(chest)
                        updated.hipsCm = value(hips)
                        updated.muscleMassKg = value(muscle)
                        if store.update(updated) { dismiss() }
                    }.fontWeight(.bold)
                }
            }
        }
    }
}
