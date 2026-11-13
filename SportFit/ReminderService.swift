import SwiftUI
import UserNotifications

@MainActor final class ReminderService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var status = "Разрешение ещё не запрашивалось"
    @Published private(set) var pending = 0
    @Published var destination: String?
    private let center = UNUserNotificationCenter.current()
    private struct Update {
        let settings: ReminderPreferences
        let run: ProgramRun?
        let draft: WorkoutDraft?
        let measurements: [BodyMeasurement]
        let history: [WorkoutResult]
    }
    private var queued: Update?
    private var updating = false
    override init() { super.init(); center.delegate = self }
    func permission() async -> Bool {
        do { return try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { status = error.localizedDescription; return false }
    }
    func refresh(settings: ReminderPreferences, run: ProgramRun?, draft: WorkoutDraft?, measurements: [BodyMeasurement], history: [WorkoutResult]) async {
        queued = Update(settings: settings, run: run, draft: draft, measurements: measurements, history: history)
        guard !updating else { return }
        updating = true; defer { updating = false }
        while let update = queued { queued = nil; await apply(update) }
    }
    private func apply(_ update: Update) async {
        let authorization = await center.notificationSettings()
        let authorized = authorization.authorizationStatus == .authorized || authorization.authorizationStatus == .provisional
        status = authorized ? "Уведомления разрешены" : authorization.authorizationStatus == .denied ? "Уведомления запрещены в настройках iOS" : "Разрешение ещё не запрашивалось"
        let old = await center.pendingNotificationRequests()
        let settings = update.settings
        let plan = ReminderPlan.make(settings: settings, run: update.run, draft: update.draft, latestMeasurement: update.measurements.map(\.measuredAt).max(), history: update.history)
        let ids = Set(plan.map(\.id))
        let retained = old.filter { request in
            settings.enabled && authorized && ((settings.completion && request.identifier.hasPrefix("sportfit.complete.")) ||
                (settings.unfinished && request.identifier.hasPrefix("sportfit.unfinished.") && ids.contains(request.identifier)))
        }
        let retainedIDs = Set(retained.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: old.map(\.identifier).filter { $0.hasPrefix("sportfit.") && !retainedIDs.contains($0) })
        pending = 0
        guard settings.enabled, authorized else { return }
        pending = retained.count
        for item in plan {
            if queued != nil { return }
            let once = item.id.hasPrefix("sportfit.complete.") || item.id.hasPrefix("sportfit.unfinished.")
            if retainedIDs.contains(item.id) || (once && UserDefaults.standard.bool(forKey: item.id)) { continue }
            do {
                try await center.add(Self.request(item))
                pending += 1
                if once { UserDefaults.standard.set(true, forKey: item.id) }
            } catch { status = "Не удалось добавить уведомление: \(error.localizedDescription)" }
        }
    }
    static func request(_ item: LocalReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = item.title; content.body = item.body; content.sound = .default
        content.userInfo = ["destination": item.destination]
        let components = SportDate.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.date)
        return UNNotificationRequest(identifier: item.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let target = response.notification.request.content.userInfo["destination"] as? String
        await MainActor.run { self.destination = target }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}

struct RemindersScreen: View {
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var service: ReminderService
    @State private var settings = ReminderPreferences()
    @State private var saving = false
    private var time: Binding<Date> {
        Binding(get: { SportDate.calendar.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: Date()) ?? Date() }, set: {
            settings.hour = SportDate.calendar.component(.hour, from: $0); settings.minute = SportDate.calendar.component(.minute, from: $0)
        })
    }
    var body: some View {
        Form {
            Section("Личные напоминания") {
                Toggle("Включить напоминания", isOn: $settings.enabled).accessibilityIdentifier("enable-reminders")
                DatePicker("Время", selection: time, displayedComponents: .hourAndMinute)
                Toggle("Тренировка или день отдыха", isOn: $settings.workout)
                ForEach(1...7, id: \.self) { day in
                    Toggle(SportDate.calendar.weekdaySymbols[day - 1], isOn: Binding(get: { settings.weekdays.contains(day) }, set: { selected in
                        settings.weekdays.removeAll { $0 == day }; if selected { settings.weekdays.append(day) }
                    }))
                }
                Text("Это удобные дни напоминаний, а не назначенная частота тренировок. Порядок нагрузки и отдыха остаётся в программе.").font(.footnote)
            }
            Section("Дополнительно") {
                Toggle("Незавершённое или пропущенное занятие", isOn: $settings.unfinished)
                Text("Одно напоминание через сутки после начала сохранённой тренировки либо на следующий день после явно отмеченного пропуска или частичного дня. Новых пропусков оно не создаёт.").font(.footnote)
                Toggle("Плановый замер", isOn: $settings.measurement)
                Picker("День замера", selection: $settings.measurementWeekday) {
                    ForEach(1...7, id: \.self) { Text(SportDate.calendar.weekdaySymbols[$0 - 1]).tag($0) }
                }
                Toggle("Сводка по воскресеньям", isOn: $settings.weekly)
                Toggle("Завершение уровня", isOn: $settings.completion)
                Text("Итоги доступны после закрытия всех дней или досрочного завершения уровня. Календарная дата окончания не назначается.").font(.footnote)
            }
            Section {
                Button("Сохранить настройки") {
                    saving = true
                    Task {
                        if settings.enabled, !(await service.permission()) { settings.enabled = false }
                        _ = journal.change { $0.reminders = settings }
                        saving = false
                    }
                }.disabled(saving || !journal.canExport).accessibilityIdentifier("save-reminders")
                Text(service.status)
                Text("Ожидают доставки: \(service.pending)")
                if let error = journal.error { Text(error).foregroundStyle(.orange) }
            }
            Section("Как работают уведомления") {
                Text("Локальные уведомления без сервера, APNs и фонового опроса. Планируются на 14 дней вперёд; открытие приложения обновляет очередь. Выключение отменяет ожидающие напоминания.")
                Text("iOS, режим фокусирования и состояние устройства влияют на доставку. Работа после истечения бесплатной подписи не подтверждена: обновляй подпись вовремя. Разрешение уведомлений не восстанавливается из резервной копии.")
                Text("Нет штрафов, баллов или сравнения с другими людьми. Явные пропуски сохраняются только по твоему решению.")
            }
        }.navigationTitle("Напоминания").onAppear { settings = journal.data.reminders }
    }
}
