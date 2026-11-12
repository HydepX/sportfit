import Foundation

enum ReportPrivacy: String, Codable, CaseIterable, Identifiable {
    case metrics = "Показатели без имени", training = "Только тренировки", full = "Полный с заметками"
    var id: String { rawValue }
}
struct GoalEvaluation: Codable, Identifiable {
    let id: UUID
    let metric: GoalMetric
    let direction: GoalDirection
    let target: Double
    let current: Double?
    let achieved: Bool?
    let progressPercent: Double?
    init(goal: QuarterGoal, current: Double?) {
        id = goal.id; metric = goal.metric; direction = goal.direction; target = goal.target; self.current = current
        achieved = current.map { goal.direction == .atMost ? $0 <= goal.target : $0 >= goal.target }
        if let current, let baseline = goal.baseline, baseline != goal.target {
            progressPercent = min(100, max(0, (current - baseline) / (goal.target - baseline) * 100))
        } else { progressPercent = nil }
    }
}
struct RunPlanSummary: Codable {
    let planned: Int
    let completed: Int
    let partial: Int
    let skipped: Int
    let remaining: Int
    let extraRestDays: Int
    var adherencePercent: Double { planned == 0 ? 0 : Double(completed) / Double(planned) * 100 }
    var consecutiveCompleted: Int
    init(run: ProgramRun, history: [WorkoutResult]) {
        planned = run.workoutCount
        var completed = 0, partial = 0, skipped = 0
        for index in 0..<run.dayCount where run.workout(on: index) != nil {
            switch run.outcome(on: index, history: history) {
            case .completed: completed += 1
            case .partial: partial += 1
            case .skipped: skipped += 1
            default: break
            }
        }
        self.completed = completed; self.partial = partial; self.skipped = skipped
        remaining = max(0, planned - completed - partial - skipped)
        extraRestDays = run.extraRests.count
        var streak = 0
        for day in run.days where run.workout(on: day.dayIndex) != nil {
            if day.outcome == .completed { streak += 1 } else { streak = 0 }
        }
        consecutiveCompleted = streak
    }
}

/// A report is a value snapshot. Later edits/imports do not rewrite saved reports.
struct QuarterReport: Codable, Identifiable {
    let format: String
    let id: UUID
    let createdAt: Date
    let title: String
    let scope: String
    let start: Date
    let end: Date
    let privacy: ReportPrivacy
    let profileName: String?
    let body: [MetricChange]
    let activity: [MetricChange]
    let training: TrainingSummary
    let plan: RunPlanSummary?
    let goals: [GoalEvaluation]
    let notes: [DayNote]
    let limitations: [String]

    static func make(title: String, scope: String, start: Date, end: Date, run: ProgramRun?, history: [WorkoutResult],
                     measurements: [BodyMeasurement], xml: [HealthRecord], journal: JournalData, name: String,
                     privacy: ReportPrivacy, now: Date = Date()) -> QuarterReport {
        let end = min(end, now)
        func included(_ date: Date) -> Bool { date >= start && date <= end }
        let workouts = history.filter { result in run.map { result.runId == $0.id } ?? included(result.finishedAt) }
        let training = TrainingSummary.make(workouts)
        let plan = run.map { RunPlanSummary(run: $0, history: history) }
        let body = privacy == .training ? [] : MeasurementMetric.allCases.flatMap { metric in
            InsightMath.changes(InsightMath.body(measurements, metric: metric, xml: xml).filter { included($0.date) }, metric: metric.rawValue)
        }
        let activity = privacy == .training ? [] : ActivityMetric.allCases.flatMap { metric in
            InsightMath.changes(InsightMath.activity(journal.activity, metric: metric, xml: xml).filter { included($0.date) }, metric: metric.rawValue)
        }
        let goals = journal.goals.filter { $0.scope == scope }.filter { privacy != .training || $0.metric.bodyMetric == nil }.map { goal -> GoalEvaluation in
            let current: Double?
            if let metric = goal.metric.bodyMetric {
                // Goals use manual/imported BodyMeasurement only; XML never silently replaces them.
                current = measurements.filter { included($0.measuredAt) }.sorted { $0.measuredAt < $1.measuredAt }.compactMap { metric.value($0) }.last
            } else if goal.metric == .workouts { current = Double(plan?.completed ?? training.completeSessions) }
            else { current = plan?.adherencePercent }
            return GoalEvaluation(goal: goal, current: current)
        }
        let notes = privacy == .full ? journal.notes.filter { note in run.map { note.runId == $0.id } ?? included(note.date) } : []
        return QuarterReport(format: "sportfit-quarter-report-v1", id: UUID(), createdAt: now, title: title, scope: scope,
            start: start, end: end, privacy: privacy, profileName: privacy == .full ? name : nil,
            body: body, activity: activity, training: training, plan: plan, goals: goals, notes: notes,
            limitations: ["Нет измерения — нет значения; пропуски не заменяются нулями.",
                "Изменение нагрузки не является медицинской оценкой или назначением следующей программы.",
                "Объём = сумма записанных повторов × внешнего веса; масса тела и множитель сторон не добавляются.",
                "Источники замеров и активности не смешиваются. XML может содержать неполный период.",
                "Квартал аналитики — 90 дней; отчёт уровня охватывает фактический период прохождения, календарный квартал выбирается отдельно."])
    }
    func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

struct JournalData: Codable {
    var format = "sportfit-journal-v1"
    var activity: [ActivityEntry] = []
    var goals: [QuarterGoal] = []
    var notes: [DayNote] = []
    var reports: [QuarterReport] = []
    var reminders = ReminderPreferences()
    func validate() throws {
        try DataValidation.require(format == "sportfit-journal-v1", "Неизвестный формат дневника")
        for ids in [activity.map(\.id), goals.map(\.id), notes.map(\.id), reports.map(\.id)] {
            try DataValidation.require(Set(ids).count == ids.count, "Повторяющиеся ID дневника")
        }
        try DataValidation.require(activity.allSatisfy(\.valid), "Некорректная активность")
        try DataValidation.require(goals.allSatisfy { !$0.scope.isEmpty && $0.metric.valid($0.target) && ($0.baseline.map { $0.isFinite } ?? true) }, "Некорректные цели")
        try DataValidation.require(notes.allSatisfy { $0.reason.count <= 100 && $0.text.count <= 2000 && ($0.dayIndex.map { $0 >= 0 && $0 < 371 } ?? true) }, "Некорректные заметки")
        for report in reports {
            try DataValidation.require(report.format == "sportfit-quarter-report-v1" && report.start <= report.end && report.title.count <= 150,
                                       "Некорректный отчёт")
        }
        try reminders.validate()
    }
}
