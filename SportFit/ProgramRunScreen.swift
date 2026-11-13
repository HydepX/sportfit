import SwiftUI

struct ProgramRunScreen: View {
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var engine: WorkoutEngine
    @State private var starting = false
    var title = "Мой план"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let run = profile.activeRun {
                        RunContent(run: run)
                    } else {
                        Image(systemName: "figure.strengthtraining.traditional").font(.largeTitle).foregroundStyle(.mint)
                        Text("Тренировки в своём темпе").font(.title.bold())
                        Text("Выбери программу и проходи дни по порядку. Даты и дни недели не ограничивают занятия. Следующий день открывается, когда ты закроешь текущий.")
                            .foregroundStyle(.secondary)
                        Button("Начать уровень") { starting = true }.buttonStyle(SportPrimaryButton()).accessibilityIdentifier("start-level")
                    }
                    if engine.draft != nil {
                        LegacyDraftButton()
                    }
                    NavigationLink("Архив уровней и результаты") { RunArchiveScreen() }
                        .buttonStyle(.bordered)
                    Text("Неделя — это блок из 7 дней программы, а не календарная неделя. Перерыв не создаёт пропусков.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .background(Color(red: 0.035, green: 0.055, blue: 0.086))
            .navigationTitle(title)
            .sheet(isPresented: $starting) { StartRunScreen() }
            .alert("SportFit", isPresented: Binding(get: { profile.error != nil || engine.notice != nil }, set: {
                if !$0 { profile.error = nil; engine.notice = nil }
            })) {
                Button("Понятно") { profile.error = nil; engine.notice = nil }
            } message: { Text(profile.error ?? engine.notice ?? "") }
        }
    }
}

private struct LegacyDraftButton: View {
    @EnvironmentObject private var engine: WorkoutEngine
    @State private var showing = false
    var body: some View {
        if let draft = engine.draft, draft.runId == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Сохранённая тренировка").font(.headline)
                Text("\(draft.title) · \(draft.completedSetCount) подходов")
                Button("Продолжить прежний черновик") { showing = true }.buttonStyle(.bordered)
                Text("Заверши её перед запуском уровня. Старые результаты останутся в журнале.").font(.footnote)
            }
            .sheet(isPresented: $showing) { WorkoutPlayer() }
        }
    }
}

private struct StartRunScreen: View {
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var engine: WorkoutEngine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selection = 0
    private var programs: [TrainingProgram] { [store.program].compactMap { $0 } + store.archivedPrograms.reversed() }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Название уровня", text: $name)
                Picker("Программа", selection: $selection) {
                    ForEach(Array(programs.enumerated()), id: \.offset) { index, program in
                        Text("\(index == 0 ? "Текущая программа" : "Архивная программа \(index)") · \(program.durationWeeks) недель").tag(index)
                    }
                }
                if programs.indices.contains(selection) {
                    let program = programs[selection]
                    Text("\(program.durationWeeks) блоков по 7 дней. Занятия и отдых идут в порядке выбранной программы.")
                    Text("Новый уровень с другой нагрузкой нужно сначала импортировать в профиле. Повтор той же программы не увеличивает нагрузку автоматически.").font(.footnote)
                    Button("Начать уровень") {
                        guard let catalog = store.catalog, store.canExport, engine.canExport else { return }
                        profile.startRun(title: name, program: program, catalog: catalog, draft: engine.draft)
                        if profile.activeRun != nil { dismiss() }
                    }.disabled(engine.draft != nil || !store.canExport || !engine.canExport || store.catalog == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("confirm-start-level")
                } else { Text("Сначала импортируй программу в профиле") }
                if engine.draft != nil { Text("Перед запуском заверши сохранённую тренировку. Она не будет удалена.") }
                if let error = profile.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Новый уровень")
            .toolbar { Button("Отмена") { dismiss() } }
            .onAppear { name = "Уровень \(profile.runs.count + 1)" }
        }
    }
}

private struct RunContent: View {
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var engine: WorkoutEngine
    @EnvironmentObject private var store: FitnessStore
    let run: ProgramRun
    @State private var showingPlayer = false
    @State private var confirmDay = false
    @State private var confirmLevel = false
    @State private var confirmRest = false
    private var active: Bool { run.closedAt == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Label(run.title, systemImage: active ? "flag.fill" : "archivebox.fill").font(.title.bold())
                Text("\(run.program.durationWeeks) недель · \(run.workoutCount) тренировок · в своём темпе")
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(run.completedDayCount), total: Double(max(1, run.dayCount))).tint(.mint)
                Text("Закрыто дней: \(run.completedDayCount) из \(run.dayCount)")
                Text("Полностью выполнено тренировок: \(run.completedWorkoutCount) из \(run.workoutCount)")
                    .font(.footnote).foregroundStyle(.secondary)
                if !run.extraRests.isEmpty { Text("Дополнительный отдых: \(run.extraRests.count)").font(.footnote) }
            }.padding().background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))

            if active, let index = run.currentDay {
                currentDay(index)
            }
            ForEach(0..<run.program.durationWeeks, id: \.self) { week in
                RunWeekSection(run: run, week: week)
            }
            if active {
                Button(run.currentDay == nil ? "Завершить уровень" : "Закрыть уровень досрочно", role: .destructive) { confirmLevel = true }
                    .disabled(engine.draft != nil)
                    .accessibilityIdentifier("close-level")
                Text("Закрытый уровень останется в архиве. Следующую программу выбираешь самостоятельно.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Уровень закрыт. Результаты и незавершённые дни сохранены в архиве.").foregroundStyle(.secondary)
            }
            NavigationLink(active ? "Цели и предварительный отчёт" : "Итоговый отчёт уровня") { ReportBuilderScreen(run: run) }
        }
        .sheet(isPresented: $showingPlayer) { WorkoutPlayer() }
        .alert("Закрыть день с неполным результатом?", isPresented: $confirmDay) {
            Button("Закрыть день и перейти дальше", role: .destructive) {
                profile.closeDay(history: engine.history, draft: engine.draft, allowIncomplete: true)
            }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Сохранённая тренировка останется частичной. День без результата будет отмечен как пропущенный. Это не полное выполнение программы.") }
        .alert("Закрыть уровень?", isPresented: $confirmLevel) {
            Button("Закрыть уровень", role: .destructive) { profile.closeRun(draft: engine.draft, allowIncomplete: true) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Полностью выполнено \(run.completedWorkoutCount) из \(run.workoutCount) тренировок. Незавершённые, частичные и пропущенные дни сохранят свои статусы. После закрытия можно запустить отдельную программу следующего уровня.")
        }
        .alert("Отметить дополнительный отдых?", isPresented: $confirmRest) {
            Button("Сегодня отдыхаю") { profile.addExtraRest() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Текущий день остаётся открытым. Занятия не сдвигаются и не считаются пропущенными. Продолжишь, когда будешь готов.") }
    }

    @ViewBuilder private func currentDay(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Сейчас · День \(index + 1)").font(.title2.bold()).accessibilityIdentifier("current-program-day")
            if let draft = engine.draft {
                Text("Сохранено подходов: \(draft.completedSetCount)")
                Button("Продолжить тренировку") { showingPlayer = true }.buttonStyle(SportPrimaryButton())
            } else if let day = run.workout(on: index) {
                Text(day.name).font(.headline)
                Text("\(day.exerciseIds.count) упражнений").foregroundStyle(.secondary)
                if run.outcome(on: index, history: engine.history) != .completed {
                    Button(run.results(on: index, history: engine.history).isEmpty ? "Начать тренировку" : "Повторить тренировку") {
                        engine.start(run: run, store: store)
                        showingPlayer = engine.draft != nil
                    }.buttonStyle(SportPrimaryButton()).disabled(!store.canExport || !profile.canExport)
                        .accessibilityIdentifier("start-workout")
                    if !run.results(on: index, history: engine.history).isEmpty {
                        Text("Повтор сохранится отдельной попыткой; прежний результат останется в журнале.").font(.footnote)
                    }
                }
                Button("Закрыть день") {
                    if run.outcome(on: index, history: engine.history) == .completed {
                        profile.closeDay(history: engine.history, draft: engine.draft, allowIncomplete: false)
                    } else { confirmDay = true }
                }.buttonStyle(.bordered).accessibilityIdentifier("close-program-day")
                Button("Дополнительный отдых") { confirmRest = true }.buttonStyle(.bordered)
                    .accessibilityIdentifier("extra-rest")
            } else {
                Label("День отдыха", systemImage: "cup.and.saucer.fill").font(.headline)
                Text("Закрой его, когда будешь готов перейти к следующему дню программы.").foregroundStyle(.secondary)
                Button("Отдых завершён — закрыть день") {
                    profile.closeDay(history: engine.history, draft: engine.draft, allowIncomplete: false)
                }.buttonStyle(SportPrimaryButton()).accessibilityIdentifier("close-rest-day")
            }
            NavigationLink("Упражнения и результаты дня") { RunDayScreen(run: run, index: index) }
            NavigationLink("Заметка или причина пропуска") { NoteEditor(runId: run.id, dayIndex: index) }
        }.padding().background(Color.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct RunWeekSection: View {
    @EnvironmentObject private var engine: WorkoutEngine
    let run: ProgramRun
    let week: Int
    @State private var expanded: Bool
    init(run: ProgramRun, week: Int) {
        self.run = run
        self.week = week
        _expanded = State(initialValue: (run.currentDay ?? 0) / 7 == week)
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 12) {
                ForEach((week * 7)..<min(week * 7 + 7, run.dayCount), id: \.self) { index in
                    NavigationLink { RunDayScreen(run: run, index: index) } label: {
                        dayCard(index)
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 12)
        } label: {
            HStack {
                Text("НЕДЕЛЯ \(week + 1)").font(.headline)
                Spacer()
                Text("\(run.days.filter { $0.dayIndex / 7 == week }.count)/7").foregroundStyle(.secondary)
            }
        }
        .onChange(of: run.currentDay) { _, index in
            if index.map({ $0 / 7 == week }) == true { expanded = true }
        }
    }
    private func dayCard(_ index: Int) -> some View {
        let status = run.outcome(on: index, history: engine.history)
        let isCurrent = run.closedAt == nil && run.currentDay == index
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("День \(index + 1)").font(.title3.bold())
                Text(run.workout(on: index).map { "\($0.exerciseIds.count) упражнений" } ?? "Отдых")
                    .font(.subheadline)
                Text(status?.title ?? (isCurrent ? "Текущий день" : run.closedAt != nil ? "Не пройдено" : "Впереди"))
                    .font(.caption)
            }
            Spacer(minLength: 4)
            Image(systemName: icon(status, rest: run.workout(on: index) == nil))
                .font(.title2).accessibilityHidden(true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(isCurrent ? Color.black : Color.white)
        .background(isCurrent ? Color.mint : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
    }
    private func icon(_ status: RunDayOutcome?, rest: Bool) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .skipped: return "forward.end.circle"
        case .rest: return "checkmark.circle"
        case nil: return rest ? "cup.and.saucer.fill" : "chevron.right"
        }
    }
}

private struct RunDayScreen: View {
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var engine: WorkoutEngine
    let run: ProgramRun
    let index: Int
    var body: some View {
        List {
            Text(run.title)
            if let status = run.outcome(on: index, history: engine.history) { Text(status.title) }
            if let day = run.workout(on: index), let date = run.sourceDate(for: index) {
                Section(day.name) {
                    ForEach(Array(day.exerciseIds.enumerated()), id: \.offset) { position, id in
                        exerciseRow(id, position: position, date: date)
                    }
                }
            } else { Label("День отдыха", systemImage: "cup.and.saucer.fill") }
            Section("Результаты") {
                ForEach(run.results(on: index, history: engine.history)) { result in
                    NavigationLink { WorkoutResultScreen(result: result) } label: {
                        VStack(alignment: .leading) {
                            Text(result.completionLabel)
                            Text(result.finishedAt, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                        }
                    }
                }
                if run.results(on: index, history: engine.history).isEmpty { Text("Сохранённых тренировок нет") }
            }
        }.navigationTitle("День \(index + 1)")
    }
    @ViewBuilder private func exerciseRow(_ id: String, position: Int, date: Date) -> some View {
        let resolved = run.program.conditionalSubstitutions?[id]?.fallback ?? id
        if let exercise = store.exercise(resolved) {
            let rule = run.program.prescription(resolved, on: date)
            NavigationLink { ExerciseDetailScreen(exercise: exercise) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(position + 1). \(exercise.title)").font(.headline)
                    Text(rule?.repetitions ?? exercise.suggestedRepsFromSource ?? "Назначения не указаны")
                    if let sets = rule?.sets { Text("\(sets) подходов").font(.caption) }
                    if let rest = rule?.restSeconds { Text("Отдых: \(rest) сек").font(.caption) }
                    if rule?.requiresClearance == true { Text(rule?.clearanceNote ?? "Нужно разрешение врача").font(.caption).foregroundStyle(.yellow) }
                }
            }
        }
    }
}

struct RunArchiveScreen: View {
    @EnvironmentObject private var profile: ProfileStore
    var body: some View {
        List {
            ForEach(profile.runs.filter { $0.closedAt != nil }.reversed()) { run in
                NavigationLink {
                    ScrollView { RunContent(run: run).padding() }.navigationTitle(run.title)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(run.title).font(.headline)
                        Text("\(run.completedWorkoutCount) из \(run.workoutCount) тренировок полностью выполнено").font(.caption)
                    }
                }
            }
            if profile.runs.allSatisfy({ $0.closedAt == nil }) { Text("Закрытых уровней пока нет") }
            NavigationLink("Вся история тренировок") {
                ScrollView { WorkoutHistoryView().padding() }.navigationTitle("История")
            }
        }.navigationTitle("Архив уровней")
    }
}
