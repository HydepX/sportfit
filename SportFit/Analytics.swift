import SwiftUI
import Charts

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
        let summary = TrainingSummary.make(workouts, exerciseId: exerciseId)
        let daySets = Dictionary(grouping: workouts, by: { SportDate.key($0.finishedAt) }).map { day, results in
            (day: day, sets: results.flatMap(\.movements).filter { exerciseId.isEmpty || $0.exerciseId == exerciseId }.reduce(0) { $0 + $1.sets.count })
        }.sorted { $0.day < $1.day }
        List {
            Picker("Период", selection: $period) {
                ForEach(AnalyticsPeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            if !daySets.isEmpty {
                Section("Подходы по дням завершения занятий") {
                    Chart(daySets, id: \.day) { item in
                        if let date = SportDate.from(item.day) { BarMark(x: .value("День", date, unit: .day), y: .value("Подходы", item.sets)).foregroundStyle(.mint) }
                    }.frame(height: 180)
                }
            }
            Picker("Упражнение", selection: $exerciseId) {
                Text("Все").tag("")
                ForEach(store.catalog?.exercises ?? []) { Text($0.title).tag($0.id) }
            }
            Section("Реальные результаты") {
                LabeledContent("Занятий с результатами", value: String(workouts.filter { $0.totalSets > 0 }.count))
                LabeledContent("Полностью выполненных дней", value: "\(summary.completeSessions)")
                LabeledContent("Частично выполненных дней", value: "\(summary.partialSessions)")
                LabeledContent("Досрочно завершено", value: String(workouts.filter(\.finishedEarly).count))
                LabeledContent("Подходов", value: "\(summary.sets)")
                LabeledContent("Повторений", value: "\(summary.reps)")
                LabeledContent("Дыхательных циклов", value: "\(summary.breathCycles)")
                LabeledContent("Времени упражнений, сек", value: "\(summary.timedSeconds)")
                LabeledContent("Время занятий без пауз, мин", value: "\(summary.durationSeconds / 60)")
                LabeledContent("Дней с подходами", value: "\(summary.activeDays)")
                LabeledContent("Активных недель", value: "\(summary.activeWeeks)")
                LabeledContent("Внешний объём, кг·повт", value: summary.externalVolumeKg.formatted(.number.precision(.fractionLength(0...1))))
                LabeledContent("Пропущено упражнений", value: String(workouts.reduce(0) { $0 + $1.skippedCount }))
                Text("Время включает разминку, упражнение и отдых, исключает ручную паузу. Объём = записанные повторы × внешний вес, без массы тела и домножения сторон. При фильтре упражнения время относится ко всему занятию. Это описание записанной работы, а не оценка силы.").font(.footnote)
            }
            if let run = profile.activeRun {
                let plan = RunPlanSummary(run: run, history: engine.history)
                Section("Текущий уровень") {
                    LabeledContent("План выполнен", value: "\(plan.completed) / \(plan.planned)")
                    ProgressView(value: Double(plan.completed), total: Double(max(1, plan.planned)))
                    Text("Подряд полностью закрыто занятий: \(plan.consecutiveCompleted). Отдых не прерывает эту последовательность; пропуски не штрафуются.").font(.footnote)
                    NavigationLink("Цели и отчёт уровня") { ReportBuilderScreen(run: run) }
                }
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
            ForEach(summary.exercises) { exercise in
                Section(exercise.title) {
                    Text("\(exercise.mode) · \(exercise.sessions) записей")
                    Text("Повторы: \(exercise.firstReps) → \(exercise.lastReps); секунды: \(exercise.firstSeconds) → \(exercise.lastSeconds)").font(.caption)
                    if let first = exercise.firstWeight, let last = exercise.lastWeight { Text("Максимальный вес подхода: \(first.formatted()) → \(last.formatted()) кг") }
                    if let first = exercise.firstVolume, let last = exercise.lastVolume { Text("Записанный объём: \(first.formatted()) → \(last.formatted()) кг·повт") }
                    if let change = exercise.volumeChangePercent { Text("Изменение внешнего объёма: \(change.formatted(.number.precision(.fractionLength(1))))%").font(.caption) }
                    if let change = exercise.weightChangePercent { Text("Изменение максимального веса: \(change.formatted(.number.precision(.fractionLength(1))))%").font(.caption) }
                    if exercise.sessions < 2 { Text("Для сравнения нужны две записи упражнения").font(.caption) }
                }
            }
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
