import Foundation

enum AnalyticsPeriod: String, Codable, CaseIterable, Identifiable {
    case week = "Неделя", month = "Месяц", quarter = "Квартал", year = "Год", all = "Всё"
    var id: String { rawValue }
    var days: Int? {
        switch self { case .week: return 7; case .month: return 30; case .quarter: return 90; case .year: return 365; case .all: return nil }
    }
    func contains(_ date: Date, now: Date = Date()) -> Bool {
        guard date <= now else { return false }
        guard let days else { return true }
        let start = SportDate.calendar.date(byAdding: .day, value: 1 - days, to: SportDate.calendar.startOfDay(for: now)) ?? now
        return date >= start
    }
}

enum MeasurementMetric: String, Codable, CaseIterable, Identifiable {
    case weight = "Вес, кг", waist = "Талия, см", chest = "Грудь, см", hips = "Бёдра, см"
    case fat = "Жир, %", muscle = "Мышцы, кг", bmi = "ИМТ"
    var id: String { rawValue }
    func value(_ entry: BodyMeasurement) -> Double? {
        switch self {
        case .weight: return entry.weightKg
        case .waist: return entry.waistCm
        case .chest: return entry.chestCm
        case .hips: return entry.hipsCm
        case .fat: return entry.bodyFatPercent
        case .muscle: return entry.muscleMassKg
        case .bmi: return entry.bmi
        }
    }
}

enum ActivityMetric: String, Codable, CaseIterable, Identifiable {
    case steps = "Шаги", pulse = "Пульс, уд/мин", sleep = "Сон, ч", energy = "Активные калории, ккал"
    var id: String { rawValue }
    func valid(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch self {
        case .steps: return (0...200_000).contains(value) && value.rounded() == value
        case .pulse: return (1...300).contains(value)
        case .sleep: return (0...24).contains(value)
        case .energy: return (0...30_000).contains(value)
        }
    }
}

struct ActivityEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var metric: ActivityMetric
    var value: Double
    var recordedAt = Date()
    var source: String { "Вручную" }
    var valid: Bool { date <= Date() && recordedAt.timeIntervalSince1970.isFinite && metric.valid(value) }
}

struct DayNote: Codable, Identifiable {
    var id = UUID()
    var runId: UUID?
    var dayIndex: Int?
    var date = Date()
    var reason: String
    var text: String
}

enum GoalMetric: String, Codable, CaseIterable, Identifiable {
    case weight = "Вес, кг", waist = "Талия, см", fat = "Жир, %", muscle = "Мышцы, кг"
    case workouts = "Полностью выполненные занятия", adherence = "Выполнение плана, %"
    var id: String { rawValue }
    var bodyMetric: MeasurementMetric? {
        switch self { case .weight: return .weight; case .waist: return .waist; case .fat: return .fat; case .muscle: return .muscle; default: return nil }
    }
    func valid(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch self {
        case .weight: return (20...400).contains(value)
        case .waist: return (10...300).contains(value)
        case .fat: return (1...75).contains(value)
        case .muscle: return (1...250).contains(value)
        case .workouts: return (1...10000).contains(value) && value.rounded() == value
        case .adherence: return (0...100).contains(value)
        }
    }
}
enum GoalDirection: String, Codable, CaseIterable { case atMost = "Не больше", atLeast = "Не меньше" }
struct QuarterGoal: Codable, Identifiable {
    var id = UUID()
    var scope: String
    var metric: GoalMetric
    var direction: GoalDirection
    var target: Double
    var baseline: Double?
    var source: String? = nil
    var createdAt = Date()
}

struct MetricPoint: Codable, Identifiable {
    var id: String { "\(date.timeIntervalSince1970):\(source):\(value)" }
    let date: Date
    let value: Double
    let source: String
}
struct MetricChange: Codable {
    let metric: String
    let source: String
    let first: MetricPoint
    let last: MetricPoint
    let count: Int
    let average: Double
    let minimum: Double
    let maximum: Double
    var difference: Double { last.value - first.value }
    var percent: Double? { first.value != 0 ? difference / first.value * 100 : nil }
}

enum InsightMath {
    static func weekKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = .current
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(c.yearForWeekOfYear ?? 0):\(c.weekOfYear ?? 0)"
    }
    static func daily(_ points: [MetricPoint], average: Bool) -> [MetricPoint] {
        Dictionary(grouping: points, by: { SportDate.key($0.date) + "|" + $0.source }).values.compactMap { group in
            guard let last = group.max(by: { $0.date < $1.date }) else { return nil }
            return MetricPoint(date: SportDate.calendar.startOfDay(for: last.date),
                               value: average ? group.reduce(0) { $0 + $1.value } / Double(group.count) : last.value, source: last.source)
        }.sorted { $0.date < $1.date }
    }
    /// Seven calendar days, equal weight per observed day, never forward-fill a gap.
    static func trend(_ points: [MetricPoint]) -> [MetricPoint] {
        var result: [MetricPoint] = []
        for (_, series) in Dictionary(grouping: daily(points, average: true), by: \.source) {
            var left = 0, sum = 0.0
            for right in series.indices {
                let point = series[right]
                let lower = SportDate.calendar.date(byAdding: .day, value: -6, to: point.date)!
                sum += point.value
                while left < right && series[left].date < lower { sum -= series[left].value; left += 1 }
                if right - left + 1 >= 2 { result.append(MetricPoint(date: point.date, value: sum / Double(right - left + 1), source: point.source)) }
            }
        }
        return result.sorted { $0.date < $1.date }
    }
    static func changes(_ points: [MetricPoint], metric: String) -> [MetricChange] {
        Dictionary(grouping: points, by: \.source).sorted { $0.key < $1.key }.compactMap { source, values in
            let sorted = values.sorted { $0.date < $1.date }
            guard let first = sorted.first, let last = sorted.last else { return nil }
            return MetricChange(metric: metric, source: source, first: first, last: last, count: sorted.count,
                                average: sorted.reduce(0) { $0 + $1.value } / Double(sorted.count), minimum: sorted.map(\.value).min()!, maximum: sorted.map(\.value).max()!)
        }
    }
    static func body(_ entries: [BodyMeasurement], metric: MeasurementMetric, xml: [HealthRecord] = []) -> [MetricPoint] {
        let manual = entries.compactMap { entry -> MetricPoint? in
            metric.value(entry).map { MetricPoint(date: entry.measuredAt, value: $0, source: "Замеры · " + (entry.source == "manual" ? "вручную" : entry.source)) }
        }
        guard metric == .weight else { return manual.sorted { $0.date < $1.date } }
        return (manual + xml.filter { $0.field == .weight }.map { MetricPoint(date: $0.end, value: $0.value, source: "XML · " + $0.source) }).sorted { $0.date < $1.date }
    }
    static func activity(_ entries: [ActivityEntry], metric: ActivityMetric, xml: [HealthRecord] = []) -> [MetricPoint] {
        let relevant = entries.filter { $0.metric == metric }
        let manual: [MetricPoint]
        if metric == .pulse { manual = daily(relevant.map { MetricPoint(date: $0.date, value: $0.value, source: $0.source) }, average: true) }
        else {
            manual = Dictionary(grouping: relevant, by: { SportDate.key($0.date) }).values.compactMap { group in
                guard let last = group.max(by: { $0.recordedAt < $1.recordedAt }) else { return nil }
                return MetricPoint(date: SportDate.calendar.startOfDay(for: last.date), value: last.value, source: last.source)
            }.sorted { $0.date < $1.date }
        }
        if metric == .pulse {
            return (manual + daily(xml.filter { $0.field == .pulse }.map { MetricPoint(date: $0.end, value: $0.value, source: "XML · " + $0.source) }, average: true)).sorted { $0.date < $1.date }
        }
        guard metric == .steps else { return manual }
        let groups = Dictionary(grouping: xml.filter { $0.field == .steps }, by: { SportDate.key($0.start) + "|" + $0.source })
        let imported: [MetricPoint] = groups.values.compactMap { group in
            guard let first = group.first, let value = try? HealthImportSummary.steps(records: group, source: first.source, day: first.start) else { return nil }
            return MetricPoint(date: SportDate.calendar.startOfDay(for: first.start), value: value, source: "XML · " + first.source)
        }
        return (manual + imported).sorted { $0.date < $1.date }
    }
}

struct ExerciseProgress: Codable, Identifiable {
    var id: String { exerciseId + "|" + mode }
    let exerciseId: String
    let title: String
    let mode: String
    let sessions: Int
    let firstWeight: Double?
    let lastWeight: Double?
    let firstVolume: Double?
    let lastVolume: Double?
    let firstReps: Int
    let lastReps: Int
    let firstSeconds: Int
    let lastSeconds: Int
}

struct TrainingSummary: Codable {
    let attempts: Int
    let completeSessions: Int
    let partialSessions: Int
    let sets: Int
    let reps: Int
    let breathCycles: Int
    let timedSeconds: Int
    let durationSeconds: Int
    let externalVolumeKg: Double
    let activeDays: Int
    let activeWeeks: Int
    let exercises: [ExerciseProgress]
    static func make(_ history: [WorkoutResult], exerciseId: String = "") -> TrainingSummary {
        let unique = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.filter {
            exerciseId.isEmpty || $0.movements.contains { $0.exerciseId == exerciseId && !$0.sets.isEmpty }
        }.sorted { $0.finishedAt < $1.finishedAt }
        func key(_ result: WorkoutResult) -> String { result.runId.map { "\($0):\(result.runDayIndex ?? -1)" } ?? "\(result.programId):\(result.date)" }
        let sessions = Dictionary(grouping: unique, by: key)
        let complete = sessions.values.filter { $0.contains(where: \.isComplete) }.count
        let movements = unique.flatMap(\.movements).filter { exerciseId.isEmpty || $0.exerciseId == exerciseId }
        let ordinary = movements.filter { !$0.isTimed && $0.prescription?.mode != "breath_cycles" }
        let measured = unique.filter { $0.totalSets > 0 }
        func movementKey(_ movement: WorkoutMovement) -> String { movement.exerciseId + "|" + (movement.prescription?.mode ?? (movement.isTimed ? "duration" : "repetitions")) }
        let progressMovements: [WorkoutMovement] = unique.flatMap { result -> [WorkoutMovement] in
            let groups = Dictionary(grouping: result.movements.filter { !$0.sets.isEmpty && (exerciseId.isEmpty || $0.exerciseId == exerciseId) }, by: movementKey)
            return groups.keys.sorted().compactMap { key -> WorkoutMovement? in
                guard let group = groups[key], var combined = group.first else { return nil }
                combined.sets = group.flatMap(\.sets); return combined
            }
        }
        let exerciseGroups = Dictionary(grouping: progressMovements, by: movementKey)
        let exercises: [ExerciseProgress] = exerciseGroups.keys.sorted().compactMap { key in
            guard let items = exerciseGroups[key], let first = items.first, let last = items.last else { return nil }
            let mode = first.prescription?.mode ?? (first.isTimed ? "duration" : "repetitions")
            func volume(_ m: WorkoutMovement) -> Double? { m.isTimed || mode == "breath_cycles" ? nil : m.sets.reduce(0) { $0 + Double($1.reps ?? 0) * ($1.weightKg ?? 0) } }
            return ExerciseProgress(exerciseId: first.exerciseId, title: first.title, mode: mode, sessions: items.count,
                firstWeight: first.sets.compactMap(\.weightKg).max(), lastWeight: last.sets.compactMap(\.weightKg).max(),
                firstVolume: volume(first), lastVolume: volume(last), firstReps: first.sets.reduce(0) { $0 + ($1.reps ?? 0) },
                lastReps: last.sets.reduce(0) { $0 + ($1.reps ?? 0) }, firstSeconds: first.sets.reduce(0) { $0 + ($1.seconds ?? 0) }, lastSeconds: last.sets.reduce(0) { $0 + ($1.seconds ?? 0) })
        }
        return TrainingSummary(attempts: unique.count, completeSessions: complete, partialSessions: sessions.count - complete,
            sets: movements.reduce(0) { $0 + $1.sets.count }, reps: ordinary.flatMap(\.sets).reduce(0) { $0 + ($1.reps ?? 0) },
            breathCycles: movements.filter { $0.prescription?.mode == "breath_cycles" }.flatMap(\.sets).reduce(0) { $0 + ($1.reps ?? 0) },
            timedSeconds: movements.filter(\.isTimed).flatMap(\.sets).reduce(0) { $0 + ($1.seconds ?? 0) },
            durationSeconds: unique.reduce(0) { $0 + $1.durationSeconds },
            externalVolumeKg: ordinary.flatMap(\.sets).reduce(0) { $0 + Double($1.reps ?? 0) * ($1.weightKg ?? 0) },
            activeDays: Set(measured.map { SportDate.key($0.finishedAt) }).count,
            activeWeeks: Set(measured.map { InsightMath.weekKey($0.finishedAt) }).count,
            exercises: exercises)
    }
}
