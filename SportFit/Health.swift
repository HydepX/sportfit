import SwiftUI
import UniformTypeIdentifiers

struct HealthScreen: View {
    @StateObject private var reader = HealthReader()
    @EnvironmentObject private var imported: HealthImportStore
    @EnvironmentObject private var measurements: MeasurementsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var selectedSource = ""
    @State private var clearing: String?
    private var stepSources: [String] { Set(imported.records.filter { $0.field == .steps }.map(\.source)).sorted() }
    private var stepSource: String { stepSources.count == 1 ? stepSources[0] : selectedSource }

    var body: some View {
        List {
            Section(reader.buildEnabled ? "Подключение" : "Локальный импорт") {
                Text(reader.buildEnabled ? "WATCH FIT 2 / Scale 3 → Huawei Health → Apple «Здоровье» → SportFit" : "Данные Huawei уже в Apple «Здоровье» можно перенести локальным export.xml.")
                Text(reader.buildEnabled ? "Сборка с HealthKit · подпись и чтение проверяются на этом iPhone" : "Сборка без HealthKit · доступны импорт и ручные замеры")
                    .accessibilityIdentifier("health-build-status")
                if reader.buildEnabled {
                    Button("Подключить вес, шаги и пульс") { Task { await reader.connect() } }
                        .disabled(reader.loading)
                    Button("Обновить сейчас") { Task { await reader.refresh(force: true) } }
                        .disabled(reader.loading || !reader.cache.connectionRequested)
                }
                if reader.buildEnabled {
                    if reader.loading { ProgressView("Проверяем три показателя") }
                    if let attempted = reader.cache.lastAttempt {
                        Text("Последняя проверка: \(attempted.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    } else { Text("Прямое чтение ещё не проверено").font(.caption) }
                    Text(reader.message).font(.footnote)
                    Text("Обновление при открытии экрана и возвращении в приложение — не чаще раза в 5 минут. Кнопка обновляет сразу. Фоновая синхронизация и передача с часов в реальном времени не выполняются.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if reader.buildEnabled {
                Section("Прямое чтение Apple Health") {
                    ForEach(reader.cache.snapshots, id: \.field) { snapshot in
                        HealthSnapshotRow(snapshot: snapshot)
                    }
                    Text("Пульс — последнее измерение, не поток с часов. Пустой ответ не различает отсутствие записей и запрет чтения. Запрос доступа сам по себе не подтверждает разрешение.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Проверка на iPhone") {
                    Text("Сборка: \(Bundle.main.object(forInfoDictionaryKey: "SportFitBuildCommit") as? String ?? "неизвестна")")
                        .font(.caption).textSelection(.enabled)
                    ForEach(reader.cache.snapshots, id: \.field) { snapshot in
                        LabeledContent(snapshot.field.title, value: diagnostic(snapshot.status))
                    }
                    Text("Для проверки подключи три категории, затем обнови экран. Если записи прочитаны, сравни дату и источник с Apple «Здоровье». Достаточно сообщить результат по категориям — значения, XML и медицинские записи присылать не нужно.")
                        .font(.footnote)
                }
            }
            Section("Импорт из файла") {
                Button("Импортировать export.xml Apple Health") { importing = true }
                    .disabled(imported.importing).accessibilityIdentifier("import-health-xml")
                if imported.importing { ProgressView("Читаем файл на устройстве") }
                Text(imported.message).font(.footnote)
                ForEach([HealthField.weight, .pulse]) { field in
                    if let record = HealthImportSummary.latest(field, records: imported.records) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(field.title): \(record.value.formatted()) \(field.unit)")
                            Text("Из файла · \(record.source) · \(record.end.formatted())").font(.caption)
                        }
                    }
                }
                if !stepSources.isEmpty {
                    Picker("Источник шагов из XML", selection: Binding(get: { stepSource }, set: { selectedSource = $0 })) {
                        Text("Выбери один источник").tag("")
                        ForEach(stepSources, id: \.self) { Text($0).tag($0) }
                    }
                    importedSteps
                }
                Text("В профиле Apple «Здоровье» экспортируй все данные. Распакуй ZIP локально и выбери export.xml; ZIP не принимается. Читаются три категории за 90 дней. Импорт не меняет Apple Health или ручные замеры и не имитирует прямую синхронизацию.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Ручные замеры") {
                if let latest = measurements.latest {
                    Text("Вес: \(latest.weightKg.formatted()) кг")
                    Text("\(latest.source) · \(latest.measuredAt.formatted())").font(.caption)
                } else { Text("Ручных измерений пока нет") }
                NavigationLink("Открыть мои замеры") { MeasurementsScreen() }
                Text("Ручные значения, прямое чтение и XML показываются отдельно. Они не складываются, не усредняются и не перезаписывают друг друга.").font(.footnote)
            }
            if reader.buildEnabled {
                Section("Дополнительные показатели") {
                    NavigationLink("Динамика и дополнительные разрешения") { HealthTrendsScreen() }
                    Text("Вес, шаги и пульс запрашиваются вместе только по кнопке подключения. Остальные категории запрашиваются отдельно, когда ты явно подключаешь выбранный показатель.").font(.footnote)
                }
            }
            Section("Локальные данные") {
                Button("Очистить кэш прямого чтения", role: .destructive) { clearing = "cache" }
                    .disabled(reader.loading)
                Button("Очистить импорт XML", role: .destructive) { clearing = "import" }
                    .disabled(imported.importing)
                Text("Кэш HealthKit и XML не входят в копию тренировок и исключены из автоматического резервного копирования. Они восстанавливаются чтением Apple Health или повторным импортом исходного файла. Перед удалением исходного XML сохрани его локально в надёжном месте.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Apple Health")
        .task { await reader.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reader.refresh() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.xml]) { result in
            switch result {
            case .success(let url): Task { await imported.importFile(url) }
            case .failure(let error): imported.message = error.localizedDescription
            }
        }
        .alert("Очистить локальные данные?", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
            Button("Очистить", role: .destructive) {
                if clearing == "cache" { reader.reset() } else { imported.reset(); selectedSource = "" }
                clearing = nil
            }
            Button("Отмена", role: .cancel) { clearing = nil }
        } message: { Text("Записи Apple Health, ручные замеры и тренировки не удаляются.") }
    }
    private var importedSteps: some View {
        Group {
            if stepSource.isEmpty { Text("Сумма разных источников не вычисляется. Выбери источник шагов.") }
            else {
                let result = Result { try HealthImportSummary.steps(records: imported.records, source: stepSource, day: Date()) }
                switch result {
                case .success(let total): Text(total.map { "Шаги сегодня из файла: \($0.formatted()) · \(stepSource)" } ?? "В файле нет шагов этого источника за сегодня")
                case .failure(let error): Text(error.localizedDescription).foregroundStyle(.orange)
                }
            }
        }.font(.footnote)
    }
    private func diagnostic(_ status: HealthQueryStatus) -> String {
        switch status {
        case .notChecked: return "Не проверено"
        case .readable: return "Запись прочитана"
        case .empty: return "Пустой ответ"
        case .failed: return "Ошибка чтения"
        }
    }
}

private struct HealthSnapshotRow: View {
    let snapshot: HealthSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.field.title).font(.headline)
            if let record = snapshot.record {
                Text("\(record.value.formatted()) \(snapshot.field.unit)")
                Text("Источник: \(record.source)").font(.caption)
                Text("Измерено: \(record.end.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                if let day = record.day { Text("Итог за \(day) · \(record.timeZone ?? "")").font(.caption) }
                if snapshot.status != .readable || snapshot.isOld() {
                    Text("Последнее известное значение · актуальность не подтверждена").font(.caption).foregroundStyle(.orange)
                } else if snapshot.newDataAt != snapshot.successfulQueryAt {
                    Text("Новых измерений нет").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("Доступных записей нет").foregroundStyle(.secondary) }
            if let success = snapshot.successfulQueryAt {
                Text("Успешный запрос: \(success.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            }
            if let changed = snapshot.newDataAt {
                Text("Последнее изменение: \(changed.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            }
            if snapshot.status == .empty { Text("Нет записей или нет доступа к чтению").font(.caption) }
            if let error = snapshot.error { Text("Последняя ошибка: \(error)").font(.caption).foregroundStyle(.orange) }
        }.padding(.vertical, 5)
    }
}
