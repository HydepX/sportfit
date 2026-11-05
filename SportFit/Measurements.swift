import SwiftUI
import Charts

struct BodyMeasurement: Codable, Identifiable {
    let id: UUID
    let measuredAt: Date
    let weightKg: Double
    let waistCm: Double?
    let bodyFatPercent: Double?
    let source: String

    init(date: Date, weightKg: Double, waistCm: Double?, bodyFatPercent: Double?) {
        self.id = UUID()
        self.measuredAt = date
        self.weightKg = weightKg
        self.waistCm = waistCm
        self.bodyFatPercent = bodyFatPercent
        self.source = "manual"
    }
}

@MainActor
final class MeasurementsStore: ObservableObject {
    @Published private(set) var entries: [BodyMeasurement] = []
    @Published var error: String?

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("body_measurements.v1.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let values = try? JSONDecoder().decode([BodyMeasurement].self, from: data) {
            entries = values.sorted { $0.measuredAt < $1.measuredAt }
        }
    }

    var latest: BodyMeasurement? { entries.last }

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
        do {
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
            return true
        } catch {
            self.error = "Не удалось сохранить измерения: \(error.localizedDescription)"
            return false
        }
    }
}

struct MeasurementsScreen: View {
    @EnvironmentObject private var store: MeasurementsStore
    @State private var showNew = false

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

                if store.entries.count >= 2 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Динамика веса").font(.headline)
                        Chart(store.entries) { entry in
                            LineMark(x: .value("Дата", entry.measuredAt),
                                     y: .value("Вес, кг", entry.weightKg))
                                .foregroundStyle(.mint)
                            PointMark(x: .value("Дата", entry.measuredAt),
                                      y: .value("Вес, кг", entry.weightKg))
                                .foregroundStyle(.mint)
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
                ForEach(store.entries.reversed()) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.measuredAt, format: .dateTime.day().month().year())
                                .font(.headline)
                            Text("Вручную" + (entry.waistCm.map { " · талия \($0) см" } ?? "")
                                 + (entry.bodyFatPercent.map { " · жир \($0)%" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(entry.weightKg.formatted(.number.precision(.fractionLength(1)))) кг")
                            .font(.headline)
                    }
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .contextMenu {
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
                Text("Показатели состава тела с биоимпедансных весов ориентировочные; важнее наблюдать изменения во времени.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Новое измерение")
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
                        if store.add(date: measuredAt,
                                     weightKg: value(weight),
                                     waistCm: waistValue,
                                     bodyFatPercent: fatValue) {
                            dismiss()
                        }
                    }.fontWeight(.bold)
                }
            }
        }
    }
}
