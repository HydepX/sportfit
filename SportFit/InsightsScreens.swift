import SwiftUI
import Charts

struct InsightsScreen: View {
    var body: some View {
        List {
            Section("Аналитический центр") {
                NavigationLink("Физическая форма") { BodyInsightsScreen() }.accessibilityIdentifier("body-insights")
                NavigationLink("Тренировочный прогресс") { WorkoutAnalyticsScreen() }.accessibilityIdentifier("training-insights")
                NavigationLink("Активность и восстановление") { ActivityInsightsScreen() }.accessibilityIdentifier("activity-insights")
            }
            Section("Итоги и следующий план") {
                NavigationLink("Отчёты уровней и кварталов") { ReportsScreen() }.accessibilityIdentifier("quarter-reports")
                Text("Следующая программа выбирается отдельно. Приложение не назначает рост нагрузки по статистике.").font(.footnote)
            }
            Section("Как читать показатели") {
                Text("Неделя — последние 7 дней, месяц — 30, квартал — 90, год — 365. «Всё» включает всю записанную историю до текущего момента.")
                Text("Пустые дни и отсутствующие значения не заменяются нулями. Источники выбираются отдельно. Линия тренда веса — среднее наблюдавшихся дней за 7 суток, минимум два дня; это не прогноз.")
            }
        }.navigationTitle("Статистика и аналитика")
    }
}

struct InsightPeriodPicker: View {
    @Binding var period: AnalyticsPeriod
    var body: some View { Picker("Период", selection: $period) { ForEach(AnalyticsPeriod.allCases) { Text($0.rawValue).tag($0) } } }
}

struct BodyInsightsScreen: View {
    @EnvironmentObject private var measurements: MeasurementsStore
    @EnvironmentObject private var imported: HealthImportStore
    @State private var period = AnalyticsPeriod.quarter
    @State private var metric = MeasurementMetric.weight
    @State private var source = ""
    private var all: [MetricPoint] { InsightMath.body(measurements.entries, metric: metric, xml: imported.records).filter { period.contains($0.date) } }
    private var sources: [String] { Set(all.map(\.source)).sorted() }
    private var selected: String { sources.contains(source) ? source : sources.first ?? "" }
    var body: some View {
        let points = all.filter { $0.source == selected }
        let trend = metric == .weight ? Array(InsightMath.trend(points).suffix(5000)) : []
        let segments = lineSegments(trend)
        List {
            InsightPeriodPicker(period: $period)
            Picker("Показатель", selection: $metric) { ForEach(MeasurementMetric.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Источник", selection: $source) { ForEach(sources, id: \.self) { Text($0).tag($0) } }
                .onAppear { source = selected }.onChange(of: sources) { _, _ in source = selected }
            NavigationLink("Добавить или сравнить мои замеры") { MeasurementsScreen() }
            if points.isEmpty { ContentUnavailableView("Нет измерений за период", systemImage: "chart.xyaxis.line", description: Text("Добавь замер или выбери другой период и источник.")) }
            else {
                Section(metric.rawValue) {
                    Chart {
                        ForEach(Array(points.suffix(5000))) { point in PointMark(x: .value("Дата", point.date), y: .value(metric.rawValue, point.value)).foregroundStyle(.secondary) }
                        ForEach(Array(trend.enumerated()), id: \.offset) { index, point in
                            LineMark(x: .value("Дата", point.date), y: .value("Тренд", point.value), series: .value("Отрезок", segments[index]))
                                .foregroundStyle(.mint)
                        }
                    }.frame(height: 230).chartYScale(domain: .automatic(includesZero: false))
                    Text("Точки — измерения. Зелёная линия — тренд веса по наблюдавшимся дням. Пробел более 7 дней разрывает линию.").font(.footnote)
                    if points.count > 5000 { Text("График показывает последние 5000 измерений. Сравнение учитывает весь выбранный период.").font(.caption) }
                }
                if let change = InsightMath.changes(points, metric: metric.rawValue).first { MetricChangeView(change: change) }
            }
            Text("Процент жира сравнивается в процентных пунктах. Мышечная масса берётся только из введённого показателя и не подменяется безжировой массой. Источники не усредняются между собой.").font(.footnote)
            if !imported.message.isEmpty { Text(imported.message).font(.footnote).foregroundStyle(.orange) }
        }.navigationTitle("Физическая форма")
    }
    private func lineSegments(_ points: [MetricPoint]) -> [Int] {
        var result: [Int] = [], segment = 0
        for index in points.indices {
            if index > 0, (SportDate.calendar.dateComponents([.day], from: points[index - 1].date, to: points[index].date).day ?? 0) > 7 { segment += 1 }
            result.append(segment)
        }
        return result
    }
}

struct MetricChangeView: View {
    let change: MetricChange
    var body: some View {
        Section(change.metric + " · " + change.source) {
            LabeledContent("Первое", value: change.first.value.formatted(.number.precision(.fractionLength(0...2))))
            Text(change.first.date.formatted(date: .abbreviated, time: .omitted)).font(.caption)
            LabeledContent("Последнее", value: change.last.value.formatted(.number.precision(.fractionLength(0...2))))
            Text(change.last.date.formatted(date: .abbreviated, time: .omitted)).font(.caption)
            if change.count >= 2 {
                LabeledContent(change.metric == MeasurementMetric.fat.rawValue ? "Изменение, п.п." : "Изменение", value: change.difference.formatted(.number.precision(.fractionLength(0...2))))
                if change.metric != MeasurementMetric.fat.rawValue, let percent = change.percent {
                    LabeledContent("Относительное изменение", value: percent.formatted(.number.precision(.fractionLength(1))) + "%")
                }
            } else { Text("Для сравнения нужны как минимум два измерения").font(.footnote) }
            LabeledContent("Наблюдений", value: "\(change.count)")
            LabeledContent("Среднее по наблюдениям", value: change.average.formatted(.number.precision(.fractionLength(0...2))))
        }
    }
}

struct ActivityInsightsScreen: View {
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var imported: HealthImportStore
    @State private var period = AnalyticsPeriod.week
    @State private var metric = ActivityMetric.steps
    @State private var source = ""
    @State private var adding = false
    @State private var editing: ActivityEntry?
    @State private var deleting: UUID?
    private var all: [MetricPoint] { InsightMath.activity(journal.data.activity, metric: metric, xml: imported.records).filter { period.contains($0.date) } }
    private var sources: [String] { Set(all.map(\.source)).sorted() }
    private var selected: String { sources.contains(source) ? source : sources.first ?? "" }
    var body: some View {
        let points = all.filter { $0.source == selected }
        List {
            InsightPeriodPicker(period: $period)
            Picker("Показатель", selection: $metric) { ForEach(ActivityMetric.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Источник", selection: $source) { ForEach(sources, id: \.self) { Text($0).tag($0) } }
                .onAppear { source = selected }.onChange(of: sources) { _, _ in source = selected }
            Button("Добавить показатель вручную") { adding = true }.accessibilityIdentifier("add-activity")
            NavigationLink("Импорт XML Apple Health") { HealthScreen() }
            if points.isEmpty { Text("Нет доступных измерений. Это отсутствие данных, а не нулевые шаги, пульс или сон.").accessibilityIdentifier("activity-empty") }
            else {
                Chart(points) { point in
                    if metric == .pulse { PointMark(x: .value("Дата", point.date), y: .value(metric.rawValue, point.value)).foregroundStyle(.mint) }
                    else { BarMark(x: .value("День", point.date, unit: .day), y: .value(metric.rawValue, point.value)).foregroundStyle(.mint) }
                }.frame(height: 220)
                LabeledContent("Дней с данными", value: "\(points.count)")
                LabeledContent("Среднее по дням с данными", value: (points.reduce(0) { $0 + $1.value } / Double(points.count)).formatted(.number.precision(.fractionLength(0...1))))
                if let last = points.last { Text("Последняя запись: " + last.date.formatted(date: .abbreviated, time: .omitted)).font(.caption) }
            }
            Section("Правила") {
                Text("Шаги, сон и активные калории — итог дня: последняя ручная запись заменяет предыдущий итог этого дня. Пульс — среднее доступных измерений за день, не пульс в реальном времени.")
                Text("XML сейчас даёт вес, шаги и пульс. Сон и калории можно записывать вручную. Разные источники не складываются. Пересекающиеся интервалы шагов XML исключаются из графика, поскольку точный итог неизвестен.")
                Text("По этим показателям приложение не рассчитывает медицинский индекс восстановления и не меняет назначения нагрузки.")
            }.font(.footnote)
            if !imported.message.isEmpty { Text(imported.message).font(.footnote).foregroundStyle(.orange) }
            Section("Мои записи") {
                ForEach(journal.data.activity.filter { $0.metric == metric && period.contains($0.date) }.sorted { $0.date > $1.date }) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(entry.value.formatted()) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                        HStack {
                            Button("Исправить") { editing = entry }.buttonStyle(.bordered)
                            Button("Удалить", role: .destructive) { deleting = entry.id }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }.navigationTitle("Активность и восстановление")
            .sheet(isPresented: $adding) { ActivityEditor(initial: nil, metric: metric) }
            .sheet(item: $editing) { ActivityEditor(initial: $0, metric: $0.metric) }
            .alert("Удалить запись активности?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Удалить", role: .destructive) { if let id = deleting { journal.change { $0.activity.removeAll { $0.id == id } } }; deleting = nil }
                Button("Отмена", role: .cancel) { deleting = nil }
            }
    }
}

struct ActivityEditor: View {
    @EnvironmentObject private var journal: JournalStore
    @Environment(\.dismiss) private var dismiss
    let initial: ActivityEntry?
    @State private var date: Date
    @State private var metric: ActivityMetric
    @State private var value: Double?
    init(initial: ActivityEntry?, metric: ActivityMetric) {
        self.initial = initial; _date = State(initialValue: initial?.date ?? Date()); _metric = State(initialValue: initial?.metric ?? metric); _value = State(initialValue: initial?.value)
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Показатель", selection: $metric) { ForEach(ActivityMetric.allCases) { Text($0.rawValue).tag($0) } }
                DatePicker("Дата измерения", selection: $date, in: ...Date())
                TextField(metric.rawValue, value: $value, format: .number).keyboardType(.decimalPad).accessibilityIdentifier("activity-value")
                Text("Шаги и калории — суточный итог, сон — часы сна за выбранный день. Для пульса укажи отдельное измерение.").font(.footnote)
                Button("Сохранить показатель") {
                    guard let value, metric.valid(value) else { journal.error = "Проверь значение и единицы показателя"; return }
                    var entry = ActivityEntry(date: date, metric: metric, value: value)
                    if let initial { entry.id = initial.id }
                    if journal.saveActivity(entry) { dismiss() }
                }.accessibilityIdentifier("save-activity")
                if let error = journal.error { Text(error).foregroundStyle(.orange) }
            }.navigationTitle(initial == nil ? "Новый показатель" : "Исправить показатель")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
}

struct NoteEditor: View {
    @EnvironmentObject private var journal: JournalStore
    @Environment(\.dismiss) private var dismiss
    var runId: UUID?
    var dayIndex: Int?
    @State private var reason = "Другое"
    @State private var text = ""
    @State private var existing: UUID?
    var body: some View {
        Form {
            Picker("Причина или сложность", selection: $reason) {
                ForEach(["Самочувствие", "Нехватка времени", "Инвентарь", "Дополнительный отдых", "Другое"], id: \.self) { Text($0).tag($0) }
            }
            TextField("Что важно учесть в следующем плане", text: $text, axis: .vertical)
            Button("Сохранить заметку") {
                var note = DayNote(runId: runId, dayIndex: dayIndex, reason: reason, text: text)
                if let existing { note.id = existing }
                if journal.saveNote(note) { dismiss() }
            }
            Text("Заметка не меняет статус дня и не создаёт медицинских назначений. В экспорт без имени и заметок этот текст не попадает.").font(.footnote)
            if let error = journal.error { Text(error).foregroundStyle(.orange) }
        }.navigationTitle("Сложности и заметки")
            .onAppear {
                if let runId, let note = journal.data.notes.first(where: { $0.runId == runId && $0.dayIndex == dayIndex }) { existing = note.id; reason = note.reason; text = note.text }
            }
    }
}
