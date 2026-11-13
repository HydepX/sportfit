import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CoreText

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum ReportExporter {
    static func text(_ report: QuarterReport) -> String {
        var lines = ["SportFit · " + report.title, report.start.formatted(date: .abbreviated, time: .omitted) + " — " + report.end.formatted(date: .abbreviated, time: .omitted), "Создан: " + report.createdAt.formatted(), "Режим: " + report.privacy.rawValue]
        if let name = report.profileName, !name.isEmpty { lines.append("Имя: " + name) }
        let training = report.training
        lines += ["", "ТРЕНИРОВКИ", "Попыток: \(training.attempts); полностью выполненных занятий: \(training.completeSessions); частичных: \(training.partialSessions)",
            "Подходов: \(training.sets); повторений: \(training.reps); дыхательных циклов: \(training.breathCycles); времени упражнений: \(training.timedSeconds) сек",
            "Время занятий без пауз: \(training.durationSeconds / 60) мин; дней с подходами: \(training.activeDays); активных недель: \(training.activeWeeks)"]
        if let plan = report.plan { lines += ["План уровня: \(plan.planned); выполнено: \(plan.completed); частично: \(plan.partial); явно пропущено: \(plan.skipped); осталось: \(plan.remaining)", "Выполнение плана: \(plan.adherencePercent.formatted(.number.precision(.fractionLength(1))))%; дополнительный отдых: \(plan.extraRestDays)"] }
        for (title, changes) in [("ФИЗИЧЕСКАЯ ФОРМА", report.body), ("АКТИВНОСТЬ И ВОССТАНОВЛЕНИЕ", report.activity)] {
            lines += ["", title]
            if changes.isEmpty { lines.append("Нет данных в этом режиме экспорта") }
            for change in changes {
                let unit = change.metric == MeasurementMetric.fat.rawValue ? " п.п." : ""
                let delta = change.count < 2 ? "сравнение недоступно: один замер" : "изменение \(change.difference.formatted(.number.precision(.fractionLength(0...2))))\(unit)"
                lines.append("\(change.metric) · \(change.source): \(change.first.value.formatted()) → \(change.last.value.formatted()); \(delta); наблюдений \(change.count)")
                lines.append("\(change.first.date.formatted(date: .abbreviated, time: .omitted)) — \(change.last.date.formatted(date: .abbreviated, time: .omitted))")
                lines.append("Среднее по наблюдениям: \(change.average.formatted()); минимум \(change.minimum.formatted()), максимум \(change.maximum.formatted())")
            }
        }
        lines += ["", "УПРАЖНЕНИЯ · первые и последние записанные результаты"]
        for exercise in training.exercises {
            lines.append("\(exercise.title) · \(exercise.mode) · занятий \(exercise.sessions): повторения \(exercise.firstReps) → \(exercise.lastReps), секунды \(exercise.firstSeconds) → \(exercise.lastSeconds)")
            if let first = exercise.firstWeight, let last = exercise.lastWeight { lines.append("Максимальный внешний вес подхода: \(first.formatted()) → \(last.formatted()) кг") }
            if let first = exercise.firstVolume, let last = exercise.lastVolume { lines.append("Записанный внешний объём: \(first.formatted()) → \(last.formatted()) кг·повт") }
            if let change = exercise.volumeChangePercent { lines.append("Изменение записанного внешнего объёма: \(change.formatted(.number.precision(.fractionLength(1))))%") }
            if let change = exercise.weightChangePercent { lines.append("Изменение максимального веса подхода: \(change.formatted(.number.precision(.fractionLength(1))))%") }
        }
        lines += ["", "ЦЕЛИ"]
        if report.goals.isEmpty { lines.append("Числовые цели не заданы") }
        for goal in report.goals { lines.append("\(goal.metric.rawValue): \(goal.direction.rawValue.lowercased()) \(goal.target.formatted()); \(goal.current.map { $0.formatted() } ?? "нет данных"); \(goal.achieved.map { $0 ? "достигнута" : "пока не достигнута" } ?? "оценка недоступна")") }
        if !report.notes.isEmpty { lines += ["", "СЛОЖНОСТИ И ПРИЧИНЫ"]; lines += report.notes.map { "\($0.reason): \($0.text)" } }
        lines += ["", "ДЛЯ СЛЕДУЮЩЕЙ ПРОГРАММЫ", "Сопоставь реальные результаты, цели и отмеченные сложности с согласованными назначениями. Новый план импортируется отдельным JSON; автоматического повышения нагрузки нет.", "", "ПРАВИЛА РАСЧЁТА"] + report.limitations
        return lines.joined(separator: "\n")
    }
    static func pdf(_ report: QuarterReport) throws -> Data {
        let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 6
        let attributed = NSAttributedString(string: Self.text(report), attributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black, .paragraphStyle: paragraph])
        let setter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 40, y: 45, width: 515, height: 752), transform: nil)
        var frames: [CTFrame] = [], offset = 0
        while offset < attributed.length {
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            try DataValidation.require(visible.length > 0 && frames.count < 500, "Отчёт слишком велик для PDF; используй JSON")
            frames.append(frame); offset += visible.length
        }
        let format = UIGraphicsPDFRendererFormat(); format.documentInfo = [kCGPDFContextCreator as String: "SportFit", kCGPDFContextTitle as String: report.title]
        return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842), format: format).pdfData { context in
            for (index, frame) in frames.enumerated() {
                context.beginPage(); let cg = context.cgContext
                cg.saveGState(); cg.translateBy(x: 0, y: 842); cg.scaleBy(x: 1, y: -1); CTFrameDraw(frame, cg); cg.restoreGState()
                ("SportFit · \(index + 1)/\(frames.count)" as NSString).draw(at: CGPoint(x: 40, y: 812), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray])
            }
        }
    }
}

struct ReportsScreen: View {
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var journal: JournalStore
    var body: some View {
        List {
            Section("Подготовить отчёт") {
                if let run = profile.activeRun { NavigationLink("Текущий уровень · цели и итоги") { ReportBuilderScreen(run: run) } }
                NavigationLink("Календарный квартал") { ReportBuilderScreen(run: nil) }.accessibilityIdentifier("calendar-report")
            }
            Section("Уровни") {
                ForEach(profile.runs.reversed()) { run in NavigationLink(run.title) { ReportBuilderScreen(run: run) } }
                if profile.runs.isEmpty { Text("После начала уровня здесь появится его отчёт") }
            }
            Section("Сохранённые снимки") {
                ForEach(journal.data.reports.sorted { $0.createdAt > $1.createdAt }) { report in
                    NavigationLink { SavedReportScreen(report: report) } label: {
                        VStack(alignment: .leading) { Text(report.title); Text(report.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                    }
                }
                if journal.data.reports.isEmpty { Text("Сохранённые отчёты остаются неизменными после новых замеров и импорта") }
            }
        }.navigationTitle("Отчёты и цели")
    }
}

struct ReportBuilderScreen: View {
    @EnvironmentObject private var engine: WorkoutEngine
    @EnvironmentObject private var measurements: MeasurementsStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var imported: HealthImportStore
    let run: ProgramRun?
    @State private var year = SportDate.calendar.component(.year, from: Date())
    @State private var quarter = (SportDate.calendar.component(.month, from: Date()) - 1) / 3 + 1
    @State private var privacy = ReportPrivacy.metrics
    @State private var addingGoal = false
    @State private var editingGoal: QuarterGoal?
    @State private var deletingGoal: UUID?
    @State private var saved = false
    private var start: Date { run.map { SportDate.calendar.startOfDay(for: $0.startedAt) } ?? SportDate.calendar.date(from: DateComponents(year: year, month: (quarter - 1) * 3 + 1, day: 1))! }
    private var end: Date {
        if let run { return run.closedAt ?? Date() }
        let boundary = SportDate.calendar.date(byAdding: .month, value: 3, to: start)!
        return Date(timeIntervalSinceReferenceDate: boundary.timeIntervalSinceReferenceDate.nextDown)
    }
    private var scope: String { run.map { "run:" + $0.id.uuidString } ?? "quarter:\(year)-Q\(quarter)" }
    private var report: QuarterReport {
        QuarterReport.make(title: run?.title ?? "\(year) · квартал \(quarter)", scope: scope, start: start, end: end, run: run,
            history: engine.history, measurements: measurements.entries, xml: imported.records, journal: journal.data, name: profile.profile.name, privacy: privacy)
    }
    var body: some View {
        let current = report
        List {
            if run == nil {
                Stepper("Год: \(year)", value: $year, in: 2000...2100)
                Picker("Квартал", selection: $quarter) { ForEach(1...4, id: \.self) { Text("Квартал \($0)").tag($0) } }
            }
            Text(run == nil ? "Календарный квартал: только фактически записанные занятия. Календарного плана и автоматических пропусков нет." : "Отчёт уровня за фактический период прохождения. 12 недель программы могут занимать больше трёх календарных месяцев.").font(.footnote)
            ReportPrivacyPicker(privacy: $privacy)
            Section("Мои цели") {
                ForEach(journal.data.goals.filter { $0.scope == scope }) { goal in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(goal.metric.rawValue)
                        Text("\(goal.direction.rawValue) \(goal.target.formatted())").font(.caption)
                        if let source = goal.source { Text(source == "manual" ? "Источник: вручную" : "Источник: " + source).font(.caption) }
                        if run.map({ $0.closedAt == nil }) ?? (end >= Date()) {
                            HStack {
                                Button("Исправить цель") { editingGoal = goal }.buttonStyle(.bordered)
                                Button("Удалить цель", role: .destructive) { deletingGoal = goal.id }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
                if run.map({ $0.closedAt == nil }) ?? (end >= Date()) { Button("Добавить числовую цель") { addingGoal = true } }
                Text("Цели задаёшь самостоятельно; пропущенные измерения означают «оценка недоступна». Цель выполнения плана оценивается только для уровня.").font(.footnote)
            }
            ReportSummaryContent(report: current)
            Section("Снимок отчёта") {
                Button(saved ? "Отчёт сохранён" : "Сохранить отчёт") { saved = journal.saveReport(current) }
                    .disabled(saved || current.start > current.end || !journal.canExport).accessibilityIdentifier("save-report")
                Text("Закрытие уровня автоматически сохраняет полный локальный снимок с заметками. Для передачи выбери режим экспорта ниже. Сохранённые отчёты не пересчитываются задним числом.").font(.footnote)
            }
            ReportExportControls(report: current)
            if let error = journal.error { Text(error).foregroundStyle(.orange) }
        }.navigationTitle("Итоги и цели")
            .sheet(isPresented: $addingGoal) { GoalEditor(scope: scope, allowAdherence: run != nil, start: start) }
            .sheet(item: $editingGoal) { GoalEditor(scope: scope, allowAdherence: run != nil, start: start, initial: $0) }
            .alert("Удалить цель периода?", isPresented: Binding(get: { deletingGoal != nil }, set: { if !$0 { deletingGoal = nil } })) {
                Button("Удалить цель", role: .destructive) {
                    if let id = deletingGoal { journal.change { $0.goals.removeAll { $0.id == id } } }
                    deletingGoal = nil; saved = false
                }
                Button("Отмена", role: .cancel) { deletingGoal = nil }
            } message: { Text("Сохранённые отчёты сохранят прежнюю цель как часть своего снимка.") }
            .onChange(of: addingGoal) { _, value in if !value { saved = false } }
            .onChange(of: editingGoal?.id) { _, value in if value == nil { saved = false } }
            .onChange(of: privacy) { _, _ in saved = false }.onChange(of: year) { _, _ in saved = false }.onChange(of: quarter) { _, _ in saved = false }
    }
}

struct ReportPrivacyPicker: View {
    @Binding var privacy: ReportPrivacy
    var body: some View {
        Section("Состав экспорта") {
            Picker("Режим", selection: $privacy) { ForEach(ReportPrivacy.allCases) { Text($0.rawValue).tag($0) } }
            Text("«Показатели без имени» сохраняет значения замеров и активности. «Только тренировки» исключает их, имя, заметки и числовые цели по телу. Это не гарантия анонимности. Файлы остаются у тебя; отправка выполняется только по твоему решению.").font(.footnote)
        }
    }
}

struct SavedReportScreen: View {
    let report: QuarterReport
    @State private var privacy = ReportPrivacy.metrics
    var body: some View {
        List {
            Text("Неизменяемый снимок от " + report.createdAt.formatted())
            ReportPrivacyPicker(privacy: $privacy)
            ReportSummaryContent(report: report.redacted(privacy))
            ReportExportControls(report: report.redacted(privacy))
        }.navigationTitle(report.title)
    }
}

struct ReportSummaryContent: View {
    let report: QuarterReport
    var body: some View {
        Section("Тренировки") {
            Text(report.start.formatted(date: .abbreviated, time: .omitted) + " — " + report.end.formatted(date: .abbreviated, time: .omitted))
            LabeledContent("Полностью выполнено занятий", value: "\(report.training.completeSessions)")
            LabeledContent("Частично", value: "\(report.training.partialSessions)")
            LabeledContent("Попыток / подходов", value: "\(report.training.attempts) / \(report.training.sets)")
            if let plan = report.plan {
                LabeledContent("По плану уровня", value: "\(plan.planned)")
                LabeledContent("Выполнено / частично / пропущено", value: "\(plan.completed) / \(plan.partial) / \(plan.skipped)")
                LabeledContent("Ещё не пройдено", value: "\(plan.remaining)")
                LabeledContent("Выполнение плана", value: plan.adherencePercent.formatted(.number.precision(.fractionLength(1))) + "%")
                Text("План учитывается по явно закрытым дням. Сохранённая, но ещё не закрытая тренировка видна среди реальных результатов, а день пока остаётся открытым.").font(.footnote)
            }
        }
        ForEach(Array(report.body.enumerated()), id: \.offset) { _, change in MetricChangeView(change: change) }
        ForEach(Array(report.activity.enumerated()), id: \.offset) { _, change in MetricChangeView(change: change) }
        if report.body.isEmpty && report.privacy != .training { Text("Для сравнения тела нет доступных замеров за этот период") }
        if report.activity.isEmpty && report.privacy != .training { Text("Активность и восстановление: данных нет") }
        Section("Оценка целей") {
            ForEach(report.goals) { goal in
                Text("\(goal.metric.rawValue): \(goal.achieved.map { $0 ? "достигнута" : "пока не достигнута" } ?? "нет данных для оценки")")
                if let progress = goal.progressPercent { Text("Движение от исходного значения: \(progress.formatted(.number.precision(.fractionLength(0))))%").font(.caption) }
            }
            if report.goals.isEmpty { Text("Числовые цели не заданы") }
        }
        Section("Прогресс в упражнениях") {
            ForEach(report.training.exercises) { exercise in
                VStack(alignment: .leading) {
                    Text(exercise.title)
                    Text("\(exercise.mode) · \(exercise.sessions) записей · повторы \(exercise.firstReps) → \(exercise.lastReps) · секунды \(exercise.firstSeconds) → \(exercise.lastSeconds)").font(.caption)
                    if let first = exercise.firstWeight, let last = exercise.lastWeight { Text("Максимальный внешний вес: \(first.formatted()) → \(last.formatted()) кг").font(.caption) }
                    if let change = exercise.volumeChangePercent { Text("Изменение внешнего объёма: \(change.formatted(.number.precision(.fractionLength(1))))%").font(.caption) }
                }
            }
        }
        if !report.notes.isEmpty {
            Section("Сложности и причины") { ForEach(report.notes) { note in Text(note.reason + ": " + note.text) } }
        }
    }
}

struct ReportExportControls: View {
    let report: QuarterReport
    @State private var exporting = false
    @State private var document: ExportDocument?
    @State private var contentType = UTType.json
    @State private var error: String?
    var body: some View {
        Section("Экспорт для следующей программы") {
            Button("Экспортировать отчёт JSON") { prepare(pdf: false) }.accessibilityIdentifier("export-report-json")
            Button("Экспортировать отчёт PDF") { prepare(pdf: true) }.accessibilityIdentifier("export-report-pdf")
            Text("JSON содержит структурированные показатели; PDF — читаемый отчёт на нескольких страницах. Приложение ничего не отправляет автоматически. Новая программа подключается отдельно, после анализа результатов.").font(.footnote)
            if let error { Text(error).foregroundStyle(.orange) }
        }.fileExporter(isPresented: $exporting, document: document, contentType: contentType,
                       defaultFilename: "sportfit-report-" + SportDate.key(report.createdAt)) { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
    }
    private func prepare(pdf: Bool) {
        do { let data = try (pdf ? ReportExporter.pdf(report) : report.json()); document = ExportDocument(data: data); contentType = pdf ? .pdf : .json; exporting = true }
        catch { self.error = error.localizedDescription }
    }
}

struct GoalEditor: View {
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var measurements: MeasurementsStore
    @Environment(\.dismiss) private var dismiss
    let scope: String
    let allowAdherence: Bool
    let start: Date
    var initial: QuarterGoal? = nil
    @State private var metric = GoalMetric.weight
    @State private var direction = GoalDirection.atMost
    @State private var value: Double?
    @State private var source = "manual"
    private var sources: [String] { Array(Set(measurements.entries.map(\.source)).union(["manual"])).sorted() }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Показатель", selection: $metric) { ForEach(GoalMetric.allCases.filter { allowAdherence || $0 != .adherence }) { Text($0.rawValue).tag($0) } }
                Picker("Условие", selection: $direction) { ForEach(GoalDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if metric.bodyMetric != nil {
                    Picker("Источник замеров цели", selection: $source) { ForEach(sources, id: \.self) { Text($0 == "manual" ? "Вручную" : $0).tag($0) } }
                }
                TextField("Целевое значение", value: $value, format: .number).keyboardType(.decimalPad)
                Button("Сохранить цель") {
                    guard let value, metric.valid(value) else { journal.error = "Проверь целевое значение и единицы"; return }
                    var baseline = metric.bodyMetric.flatMap { selected in measurements.entries.filter { $0.measuredAt <= Date() && $0.measuredAt >= start && $0.source == source }.compactMap { selected.value($0) }.first } ?? (metric.bodyMetric == nil ? 0 : nil)
                    if let initial, initial.metric == metric && (initial.source ?? "manual") == source { baseline = initial.baseline }
                    var goal = QuarterGoal(scope: scope, metric: metric, direction: direction, target: value, baseline: baseline, source: metric.bodyMetric == nil ? nil : source)
                    if let initial { goal.id = initial.id; goal.createdAt = initial.createdAt }
                    if journal.saveGoal(goal) { dismiss() }
                }
                Text("Приложение не назначает цели. Укажи согласованное значение самостоятельно. Замеры цели берутся только из выбранного источника, XML не подмешивается. Без исходного измерения процент продвижения не вычисляется.").font(.footnote)
                if let error = journal.error { Text(error).foregroundStyle(.orange) }
            }.navigationTitle("Цель периода").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
                .onAppear { if let initial { metric = initial.metric; direction = initial.direction; value = initial.target; source = initial.source ?? "manual" } }
        }
    }
}
