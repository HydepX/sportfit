import SwiftUI
import UniformTypeIdentifiers

struct ProgressScreen: View {
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var engine: WorkoutEngine
    @EnvironmentObject private var measurements: MeasurementsStore
    @Binding var destination: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NavigationLink {
                        MeasurementsScreen()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Измерения тела").font(.headline)
                                if let weight = measurements.latest?.weightKg {
                                    Text("\(weight.formatted(.number.precision(.fractionLength(1)))) кг — последний вес")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    Text("Добавь первый вес, талию и процент жира")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.mint)
                        }.padding().background(.white.opacity(0.07),
                                                in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain)
                    NavigationLink("Статистика и отчёты") { InsightsScreen() }.accessibilityIdentifier("open-insights")
                    Text("Журнал тренировок").font(.title2.bold())
                    WorkoutHistoryView()
                }.padding()
            }.background(Color(red: 0.035, green: 0.055, blue: 0.086))
                .navigationTitle("Прогресс")
                .navigationDestination(item: $destination) { target in
                    if target == "measurements" { MeasurementsScreen() }
                    else { ReportsScreen() }
                }
        }
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var engine: WorkoutEngine
    @EnvironmentObject private var measurements: MeasurementsStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var journal: JournalStore
    @State private var importingBackup = false
    @State private var importingMeasurements = false
    @State private var pendingBackup: SportFitBackup?
    @State private var confirmRestore = false
    @State private var importingCatalog = false
    @State private var importingProgram = false
    @State private var exportingBackup = false
    @State private var backupDocument: SportFitBackupDocument?

    var body: some View {
        NavigationStack {
            Form {
                Section("Профиль") {
                    NavigationLink("Личные данные и цели") { ProfileEditor() }
                    NavigationLink("Библиотека упражнений") { LibraryScreen() }
                    NavigationLink("Архив и отчёты программ") { ReportsScreen() }
                    NavigationLink("Напоминания") { RemindersScreen() }.accessibilityIdentifier("open-reminders")
                    NavigationLink("Данные и резервные копии") { StorageScreen() }.accessibilityIdentifier("open-storage")
                }
                Section("Данные программы") {
                    Label(store.catalog == nil ? "Каталог не загружен" : "Каталог: \(store.catalog?.currentExercises.count ?? 0) упражнений",
                          systemImage: "books.vertical")
                    Button("Импортировать exercises.v1.json") { importingCatalog = true }
                    Label(store.program == nil ? "План не загружен" : "12-недельный план загружен",
                          systemImage: "calendar")
                    Button("Импортировать программу JSON (v1 / v2)") { importingProgram = true }
                    Text("Выбери распакованный program_12w_with_sets.v2.json или совместимый план v1, не ZIP-архив.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Резервная копия") {
                    Button("Экспортировать мои данные") {
                        guard store.canExport && engine.canExport && measurements.canExport && profile.canExport && journal.canExport else {
                            store.message = "Часть файлов не прочитана. Не создавай неполную копию; сохрани исходные файлы перед восстановлением."
                            return
                        }
                        backupDocument = SportFitBackupDocument(
                            backup: SportFitBackup(engine: engine, measurements: measurements,
                                                   store: store, profile: profile, journal: journal))
                        exportingBackup = true
                    }
                    Button("Восстановить из резервной копии") { importingBackup = true }
                    Text("Копия v4 включает историю, черновик, уровни и программы, профиль, замеры, ручную активность, цели, заметки и отчёты. Кэш Apple Health и XML не входят; отчёты могут содержать их сводки. Восстановление заменяет данные после подтверждения и выключает напоминания. Храни внешнюю копию локально вне приложения.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Apple Health") {
                    NavigationLink("Apple Health и источники") { HealthScreen() }.accessibilityIdentifier("open-health")
                    Button("Импортировать измерения JSON") { importingMeasurements = true }
                    Text("Прямое чтение требует сборки с HealthKit и проверки подписи на iPhone. Обычная сборка поддерживает локальный импорт Apple Health XML без этого capability.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("О приложении") {
                    Text("SportFit \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · сборка \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                    Text("Коммит: \(Bundle.main.object(forInfoDictionaryKey: "SportFitBuildCommit") as? String ?? "неизвестен")")
                        .font(.caption).textSelection(.enabled)
                    Text("Хранение: только на устройстве. Фото и видео упражнений будут добавлены позже.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.035, green: 0.055, blue: 0.086))
            .navigationTitle("Профиль")
            .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json]) { result in
                do {
                    pendingBackup = try BackupRestore.read(result.get(), store: store)
                    confirmRestore = true
                } catch { store.message = error.localizedDescription }
            }
            .fileImporter(isPresented: $importingMeasurements, allowedContentTypes: [.json]) { result in
                do { try measurements.importFile(result.get()); store.message = "Измерения импортированы" }
                catch { store.message = error.localizedDescription }
            }
            .alert("Заменить данные приложения?", isPresented: $confirmRestore) {
                Button("Отмена", role: .cancel) { pendingBackup = nil }
                Button("Восстановить", role: .destructive) {
                    guard let backup = pendingBackup else { return }
                    do {
                        try BackupRestore.restore(backup, engine: engine, measurements: measurements, store: store, profile: profile, journal: journal)
                        store.message = "Резервная копия восстановлена"
                    } catch { store.message = "Восстановление не завершено: \(error.localizedDescription)" }
                    pendingBackup = nil
                }
            } message: { Text(pendingBackup.map { "Копия от \($0.exportedAt.formatted()): \($0.workouts.count) тренировок, \($0.manualMeasurements.count) замеров, \($0.runs?.count ?? 0) уровней. Текущие данные заменятся; если они читаются, перед заменой будет сохранена локальная копия." } ?? "") }
            .fileImporter(isPresented: $importingCatalog,
                          allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.importJSON(from: url, kind: .catalog)
                }
            }
            .fileImporter(isPresented: $importingProgram,
                          allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.importJSON(from: url, kind: .program)
                }
            }
            .fileExporter(isPresented: $exportingBackup, document: backupDocument,
                          contentType: .json, defaultFilename: "sportfit-backup-" + SportDate.key(Date())) { result in
                if case .failure(let error) = result {
                    store.message = "Не удалось экспортировать копию: \(error.localizedDescription)"
                }
            }
        }
    }
}
