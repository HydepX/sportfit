import Foundation

enum HistoryPeriod: String, CaseIterable, Identifiable {
    case week = "Последние 7 дней", month = "Последние 30 дней", custom = "Выбрать даты", all = "Вся история"
    var id: String { rawValue }
}

struct HistoryFilter {
    var period: HistoryPeriod = .week
    var start: Date = Date()
    var end: Date = Date()
    func contains(_ date: Date, now: Date = Date()) -> Bool {
        let calendar = SportDate.calendar
        let lower: Date
        let upper: Date
        switch period {
        case .week, .month:
            lower = calendar.date(byAdding: .day, value: period == .week ? -6 : -29, to: calendar.startOfDay(for: now)) ?? now
            upper = now
        case .custom:
            lower = calendar.startOfDay(for: min(start, end))
            upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(start, end))) ?? end
            return date >= lower && date < upper && date <= now
        case .all: return date <= now
        }
        return date >= lower && date <= upper
    }
}
