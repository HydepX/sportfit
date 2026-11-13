import SwiftUI
import UniformTypeIdentifiers

struct LocalBackupItem: Identifiable {
    var id: String { url.lastPathComponent }
    let url: URL
    let date: Date
    let bytes: Int
}

@MainActor enum BackupVault {
    static func items(directory: URL) -> [LocalBackupItem] {
        let folder = directory.appendingPathComponent("Backups", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []).filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("sportfit-") }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return LocalBackupItem(url: url, date: values.contentModificationDate ?? .distantPast, bytes: values.fileSize ?? 0)
        }.sorted { $0.date > $1.date }
    }
    @discardableResult static func save(_ backup: SportFitBackup, directory: URL, kind: String = "manual") throws -> URL {
        try BackupRestore.validate(backup, fallback: backup.catalog)
        let folder = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sportfit-\(kind)-\(SportDate.key(backup.exportedAt))-\(UUID().uuidString.prefix(8)).json")
        let bytes = try BackupEnvelope.encode(backup)
        _ = try BackupEnvelope.decode(bytes)
        try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if kind == "auto" {
            for item in items(directory: directory).filter({ $0.url.lastPathComponent.hasPrefix("sportfit-auto-") }).dropFirst(7) { try FileManager.default.removeItem(at: item.url) }
        }
        return file
    }
    static func automatic(engine: WorkoutEngine, measurements: MeasurementsStore, store: FitnessStore, profile: ProfileStore, journal: JournalStore, now: Date = Date()) throws {
        guard engine.canExport && measurements.canExport && store.canExport && profile.canExport && journal.canExport,
              !engine.history.isEmpty || !measurements.entries.isEmpty || !profile.runs.isEmpty || !journal.data.activity.isEmpty else { return }
        if let newest = items(directory: store.directory).first(where: { $0.url.lastPathComponent.hasPrefix("sportfit-auto-") }), now.timeIntervalSince(newest.date) < 86400 { return }
        try save(SportFitBackup(engine: engine, measurements: measurements, store: store, profile: profile, journal: journal), directory: store.directory, kind: "auto")
    }
}

struct StorageScreen: View {
    @EnvironmentObject private var engine: WorkoutEngine
    @EnvironmentObject private var measurements: MeasurementsStore
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var journal: JournalStore
    @State private var items: [LocalBackupItem] = []
    @State private var pending: SportFitBackup?
    @State private var restoring = false
    @State private var exporting = false
    @State private var document: ExportDocument?
    @State private var deleting: LocalBackupItem?
    @State private var message = ""
    @State private var exportFilename = "sportfit-backup"
    private var healthy: Bool { engine.canExport && measurements.canExport && store.canExport && profile.canExport && journal.canExport }
    var body: some View {
        List {
            Section("Долговременное хранение") {
                Text("Тренировок: \(engine.history.count) · уровней: \(profile.runs.count) · замеров: \(measurements.entries.count) · отчётов: \(journal.data.reports.count)")
                Text("Завершённые тренировки — SQLite с неизменяемыми записями и контрольными суммами. Программы, черновик и дневник сохраняются атомарно. Нет аккаунта, сервера и автоматической передачи данных.").font(.footnote)
                Text(healthy ? "Хранилища доступны" : "Часть данных не прочитана. Сначала восстанови копию; исходные файлы не удаляются.").foregroundStyle(healthy ? Color.secondary : Color.orange)
            }
            Section("Резервные копии v4") {
                Button("Создать локальную копию сейчас") {
                    do {
                        try BackupVault.save(SportFitBackup(engine: engine, measurements: measurements, store: store, profile: profile, journal: journal), directory: store.directory)
                        refresh(); message = "Локальная копия создана. Для переноса сохрани её также вне приложения."
                    } catch { message = error.localizedDescription }
                }.disabled(!healthy).accessibilityIdentifier("create-local-backup")
                Text("При открытии приложения создаётся не более одной автоматической копии за 24 часа, хранятся последние 7. Ручные и предварительные копии не удаляются автоматически. Копия внутри приложения не защищает от его удаления.").font(.footnote)
                Text("В v4 входят история, уровни и программы, черновик, профиль, замеры, ручная активность, цели, заметки и отчёты. XML и кэш Apple Health остаются отдельно и в копию не входят. Отчёты могут содержать ранее сохранённые сводки этих показателей.").font(.footnote)
            }
            Section("Сохранённые локальные копии") {
                if items.isEmpty { Text("Копий пока нет") }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.date.formatted())
                        Text(item.url.lastPathComponent).font(.caption)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)).font(.caption)
                        HStack {
                            Button("Сохранить во «Файлы»") {
                                do { let data = try Data(contentsOf: item.url); _ = try BackupEnvelope.decode(data); document = ExportDocument(data: data); exportFilename = item.url.deletingPathExtension().lastPathComponent; exporting = true }
                                catch { message = error.localizedDescription }
                            }.buttonStyle(.bordered)
                            Button("Восстановить") {
                                do { pending = try BackupRestore.read(item.url, store: store); restoring = true }
                                catch { message = error.localizedDescription }
                            }.buttonStyle(.bordered)
                        }
                        Button("Удалить эту копию", role: .destructive) { deleting = item }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Перенос на другой iPhone") {
                Text("Экспортируй копию во «Файлы» вне контейнера SportFit и перенеси её локально. Установи приложение на другом iPhone, затем в профиле выбери восстановление. Проверь дату копии и количество тренировок. Разрешение уведомлений выдаётся заново.")
                Text("Обновляй приложение поверх прежнего с тем же Apple ID и bundle ID. Удаление приложения удаляет контейнер и внутренние копии. Симулятор проверяет сохранение контейнера при повторной установке; фактическую переподпись через AltServer нужно проверить на iPhone.")
                Text("Файлы приложения исключаются из автоматического резервного копирования iOS. Держи внешнюю копию на доверенном локальном носителе; приложение не отправляет её в облако.")
            }.font(.footnote)
            if !message.isEmpty { Text(message).accessibilityIdentifier("storage-message") }
        }.navigationTitle("Данные и копии").onAppear { refresh() }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: exportFilename) { result in
                if case .failure(let error) = result { message = error.localizedDescription }
            }
            .alert("Восстановить выбранную копию?", isPresented: $restoring) {
                Button("Восстановить", role: .destructive) {
                    guard let pending else { return }
                    do { try BackupRestore.restore(pending, engine: engine, measurements: measurements, store: store, profile: profile, journal: journal); refresh(); message = "Восстановлено. Напоминания выключены до явного включения." }
                    catch { message = error.localizedDescription }
                    self.pending = nil
                }
                Button("Отмена", role: .cancel) { pending = nil }
            } message: {
                Text(pending.map { "Копия от \($0.exportedAt.formatted()): \($0.workouts.count) тренировок, \($0.manualMeasurements.count) замеров, \($0.runs?.count ?? 0) уровней. Текущие данные заменятся. Если они читаются, перед заменой будет сохранена отдельная локальная копия." } ?? "")
            }
            .alert("Удалить только эту резервную копию?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Удалить копию", role: .destructive) {
                    if let item = deleting { do { try FileManager.default.removeItem(at: item.url); refresh() } catch { message = error.localizedDescription } }; deleting = nil
                }
                Button("Отмена", role: .cancel) { deleting = nil }
            } message: { Text("История тренировок и остальные копии сохранятся.") }
    }
    private func refresh() { items = BackupVault.items(directory: store.directory) }
}
