import Foundation

struct ReminderPreferences: Codable, Equatable {
    var enabled = false
    var workout = true
    var unfinished = false
    var measurement = false
    var weekly = false
    var completion = true
    var hour = 19
    var minute = 0
    var weekdays = [2, 4, 6] // Optional preferred days, not a prescribed training schedule.
    var measurementWeekday = 1
    func validate() throws {
        try DataValidation.require((0...23).contains(hour) && (0...59).contains(minute) &&
            weekdays.allSatisfy { (1...7).contains($0) } && Set(weekdays).count == weekdays.count && (1...7).contains(measurementWeekday),
                                   "Некорректное время напоминаний")
    }
}
struct LocalReminder: Identifiable {
    let id: String
    let date: Date
    let title: String
    let body: String
    let destination: String
}
enum ReminderPlan {
    /// Bounded one-shot requests; opening the app replenishes the 14-day horizon.
    /// No skipped workout or future completion date is inferred from elapsed time.
    static func make(settings: ReminderPreferences, run: ProgramRun?, draft: WorkoutDraft?, latestMeasurement: Date?,
                     history: [WorkoutResult], now: Date = Date(), calendar: Calendar = SportDate.calendar) -> [LocalReminder] {
        guard settings.enabled, (try? settings.validate()) != nil else { return [] }
        var result: [LocalReminder] = []
        for offset in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let date = calendar.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: day), date > now else { continue }
            let weekday = calendar.component(.weekday, from: day)
            if settings.workout, let run, run.closedAt == nil, run.currentDay != nil, settings.weekdays.contains(weekday),
               !history.contains(where: { calendar.isDate($0.finishedAt, inSameDayAs: day) && $0.totalSets > 0 }) {
                result.append(LocalReminder(id: "sportfit.workout.\(SportDate.key(day))", date: date, title: "Время для своего плана",
                    body: "Открой текущий день программы. Если нужен отдых, продолжишь позже.", destination: "plan"))
            }
            if settings.measurement, weekday == settings.measurementWeekday,
               !(latestMeasurement.map { calendar.isDate($0, inSameDayAs: day) } ?? false) {
                result.append(LocalReminder(id: "sportfit.measure.\(SportDate.key(day))", date: date, title: "Плановый замер",
                    body: "Если удобно, добавь измерение в дневник.", destination: "measurements"))
            }
            if settings.weekly, weekday == 1 {
                result.append(LocalReminder(id: "sportfit.weekly.\(SportDate.key(day))", date: date, title: "Недельная сводка",
                    body: "Посмотри результаты последних семи дней в разделе «Прогресс».", destination: "progress"))
            }
        }
        if settings.unfinished, let draft {
            let earliest = max(now.addingTimeInterval(60), draft.startedAt.addingTimeInterval(86400))
            result.append(LocalReminder(id: "sportfit.unfinished.\(draft.id)", date: earliest, title: "Есть сохранённая тренировка",
                body: "Можно продолжить или завершить её, когда будет удобно. Пропуск не выставляется.", destination: "plan"))
        }
        if settings.completion, let run, run.currentDay == nil || run.closedAt != nil {
            result.append(LocalReminder(id: "sportfit.complete.\(run.id)", date: now.addingTimeInterval(5), title: "Итоги уровня",
                body: "Открой отчёт и сохрани результаты перед выбором следующей программы.", destination: "reports"))
        }
        return result.sorted { $0.date < $1.date }.prefix(48).map { $0 }
    }
}
