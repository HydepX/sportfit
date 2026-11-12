import SwiftUI
import Charts

enum AnalyticsPeriod: String, CaseIterable, Identifiable {
    case week = "Неделя", month = "Месяц", quarter = "Квартал", year = "Год", all = "Всё"
    var id: String { rawValue }
    func contains(_ date: Date, now: Date = Date()) -> Bool {
        let component: Calendar.Component
        let amount: Int
        switch self {
        case .week: component = .day; amount = -7
        case .month: component = .month; amount = -1
        case .quarter: component = .month; amount = -3
        case .year: component = .year; amount = -1
        case .all: return date <= now
        }
        let start = SportDate.calendar.date(byAdding: component, value: amount, to: now) ?? now
        return date >= start && date <= now
    }
}

struct WorkoutAnalyticsScreen: View {
    @EnvironmentObject private var engine: WorkoutEngine
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var profile: ProfileStore
    @State private var period = AnalyticsPeriod.week
    @State private var exerciseId = ""
    private var workouts: [WorkoutResult] {
        engine.history.filter { period.contains($0.finishedAt) &&
            (exerciseId.isEmpty || $0.movements.contains { $0.exerciseId == exerciseId && !$0.sets.isEmpty }) }
    }
    private var sets: [ActualSet] {
        workouts.flatMap(\.movements).filter { exerciseId.isEmpty || $0.exerciseId == exerciseId }.flatMap(\.sets)
    }
    var body: some View {
        List {
            Picker("Период", selection: $period) {
                ForEach(AnalyticsPeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Упражнение", selection: $exerciseId) {
                Text("Все").tag("")
                ForEach(store.catalog?.exercises ?? []) { Text($0.title).tag($0.id) }
            }
            Section("Реальные результаты") {
                LabeledContent("Занятий с результатами", value: String(workouts.filter { $0.totalSets > 0 }.count))
                LabeledContent("Досрочно завершено", value: String(workouts.filter(\.finishedEarly).count))
                LabeledContent("Подходов", value: String(sets.count))
                LabeledContent("Время, мин", value: String(workouts.reduce(0) { $0 + $1.durationSeconds } / 60))
                LabeledContent("Пропущено упражнений", value: String(workouts.reduce(0) { $0 + $1.skippedCount }))
            }
            if !exerciseId.isEmpty && sets.count > 1 {
                Section("Рабочий вес, кг") {
                    Chart(sets) { item in
                        if let kg = item.weightKg {
                            PointMark(x: .value("Дата", item.completedAt), y: .value("кг", kg))
                        }
                    }.frame(height: 180)
                    Chart(sets) { item in
                        if let reps = item.reps {
                            PointMark(x: .value("Дата", item.completedAt), y: .value("Повторы", reps))
                        }
                    }.frame(height: 180)
                }
            }
            if workouts.isEmpty { Text("За выбранный период результатов пока нет") }
            Section("Уровни и версии программ") {
                NavigationLink("Архив уровней") { RunArchiveScreen() }
                ForEach(Array((store.archivedPrograms + [store.program].compactMap { $0 }).enumerated()), id: \.offset) { _, program in
                    NavigationLink {
                        ProgramReportScreen(program: program)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(program.programId)
                            Text("\(program.startDate) — \(program.endDate)").font(.caption)
                        }
                    }
                }
            }
            ForEach(workouts.sorted { $0.finishedAt > $1.finishedAt }) { workout in
                NavigationLink { WorkoutResultScreen(result: workout) } label: {
                    VStack(alignment: .leading) {
                        Text(workout.title)
                        Text("\(workout.date) · \(workout.totalSets) подходов").font(.caption)
                    }
                }
            }
        }.navigationTitle("Статистика")
    }
}

struct WorkoutResultScreen: View {
    let result: WorkoutResult
    var body: some View {
        List {
            Text("Выполнено: " + result.finishedAt.formatted(date: .long, time: .shortened))
            if let index = result.runDayIndex { Text("День программы: \(index + 1)") }
            Text((result.runId == nil ? "Дата по плану: " : "Дата начала: ") + result.date)
            Text("Длительность: \(result.durationSeconds / 60) мин · подходов: \(result.totalSets)")
            Text(result.completionLabel)
            ForEach(result.movements) { movement in
                Section(movement.title) {
                    Text("План: \(movement.prescription?.sets.map { "\($0) подходов × " } ?? "")\(movement.target)")
                    if let rest = movement.prescription?.restSeconds { Text("Отдых: \(rest) сек").font(.caption) }
                    if movement.skipped { Text("Пропущено: \(movement.skipReason ?? "Без причины")") }
                    if movement.sets.isEmpty && !movement.skipped { Text("Нет выполненных подходов") }
                    ForEach(Array(movement.sets.enumerated()), id: \.element.id) { index, actual in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Подход \(index + 1)").font(.subheadline.bold())
                            if let seconds = actual.seconds { Text("Факт: \(seconds) сек") }
                            else {
                                let unit = movement.prescription?.mode == "breath_cycles" ? "дыхательных циклов" : movement.prescription?.mode == "repetitions_per_side" ? "на каждую сторону" : "повторов"
                                Text("Факт: \(actual.reps ?? 0) \(unit) · \((actual.weightKg ?? 0).formatted()) кг")
                            }
                        }
                    }
                }
            }
        }.navigationTitle(result.title)
    }
}

struct ProgramReportScreen: View {
    @EnvironmentObject private var engine: WorkoutEngine
    @EnvironmentObject private var profile: ProfileStore
    let program: TrainingProgram
    private var results: [WorkoutResult] { engine.history.filter { $0.runId == nil && $0.programId == program.programId } }
    private var plannedDates: [String] {
        guard let start = SportDate.from(program.startDate) else { return [] }
        return (0..<(program.durationWeeks * 7)).compactMap { offset in
            guard let date = SportDate.calendar.date(byAdding: .day, value: offset, to: start), date <= Date(),
                  let day = program.day(on: date) else { return nil }
            _ = day
            return SportDate.key(date)
        }
    }
    var body: some View {
        List {
            Text("Исторический отчёт прежнего календаря. Последовательные уровни учитываются отдельно в архиве.").font(.footnote)
            Text("\(program.startDate) — \(program.endDate)")
            let completed = Set(results.filter(\.isComplete).map(\.date))
            let due = Set(plannedDates)
            LabeledContent("Все упражнения отмечены", value: String(completed.intersection(due).count))
            LabeledContent("Запланировано к сегодня", value: String(due.count))
            if !due.isEmpty {
                LabeledContent("Доля отмеченных занятий", value: "\(Int(Double(completed.intersection(due).count) / Double(due.count) * 100))%")
            }
            Text("Оценка проверяет отмеченные упражнения и количество подходов, когда оно задано. Если подходы не назначены в JSON, по одному подходу нельзя оценить выполнение всей нагрузки.").font(.footnote)
            LabeledContent("Явно пропущено", value: String(profile.changes.filter { $0.programId == program.programId && $0.skipped }.count))
            LabeledContent("Перенесено", value: String(profile.changes.filter { $0.programId == program.programId && $0.movedTo != nil }.count))
            ForEach(program.phases) { phase in
                Section(phase.title) {
                    Text(phase.subtitle)
                    ForEach(Array(phase.days.enumerated()), id: \.offset) { _, day in
                        Text("\(day.dayOfWeek): \(day.name)")
                    }
                }
            }
        }.navigationTitle("Отчёт программы")
    }
}
