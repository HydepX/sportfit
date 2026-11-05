import SwiftUI

struct WorkoutPlayer: View {
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var engine: WorkoutEngine
    @Environment(\.dismiss) private var dismiss
    @State private var editingSet: ActualSet?
    @State private var showOrder = false
    @State private var repsText = ""
    @State private var weightText = "0"
    @State private var secondsText = ""
    @State private var feeling = "Как раз"
    @State private var skipSheet = false
    @State private var showDiscard = false
    @State private var currentSecond = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var draft: WorkoutDraft? { engine.draft }
    private var current: WorkoutMovement? {
        guard let d = draft, d.movements.indices.contains(d.currentIndex) else { return nil }
        return d.movements[d.currentIndex]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let draft, let movement = current {
                    ScrollView {
                        VStack(spacing: 20) {
                            HStack {
                                Text("Упражнение \(draft.currentIndex + 1) из \(draft.movements.count)")
                                Spacer()
                                Text(phaseTitle(draft.phase)).foregroundStyle(.mint)
                            }.font(.caption.bold()).foregroundStyle(.secondary)

                            ProgressView(value: Double(draft.currentIndex + 1),
                                         total: Double(max(1, draft.movements.count)))
                                .tint(.mint)

                            ExerciseMediaView(exerciseId: movement.exerciseId)

                            Text(movement.title).font(.title2.bold()).multilineTextAlignment(.center)
                            Text(movement.target).foregroundStyle(.secondary)
                            if movement.sourceId != movement.exerciseId {
                                Text("Используется щадящая замена: \(movement.sourceId) → \(movement.exerciseId)")
                                    .font(.footnote).foregroundStyle(.yellow)
                                    .multilineTextAlignment(.center)
                            }
                            Text("Выполнено подходов: \(movement.sets.count)")
                                .font(.subheadline).foregroundStyle(.mint)

                            if let exercise = store.exercise(movement.exerciseId) {
                                NavigationLink {
                                    ExerciseDetailScreen(exercise: exercise)
                                } label: {
                                    Label("Посмотреть технику", systemImage: "info.circle")
                                }.tint(.mint)
                            }

                            if let rule = movement.prescription {
                                if let count = rule.sets { Text("План: \(count) подходов") }
                                if let progression = rule.progression { Text(progression).font(.footnote) }
                            } else {
                                Text("Подходы и прогрессия не заданы в JSON. Не увеличивай нагрузку без согласованного плана.").font(.footnote).foregroundStyle(.secondary)
                            }
                            if draft.phase != .summary {
                                ForEach(movement.sets) { actual in
                                    HStack {
                                        Text(actual.seconds.map { "\($0) сек" } ?? "\(actual.reps ?? 0) × \((actual.weightKg ?? 0).formatted()) кг")
                                        Spacer()
                                        Button("Исправить") { editingSet = actual }
                                        Button(role: .destructive) { engine.deleteSet(actual.id) } label: {
                                            Image(systemName: "trash")
                                        }.accessibilityLabel("Удалить подход")
                                    }
                                }
                                if draft.phase == .prepare {
                                    Button("Порядок упражнений") { showOrder = true }
                                }
                            }
                            phaseContent(draft: draft, movement: movement)
                        }
                        .padding(18)
                    }
                } else {
                    ContentUnavailableView("Нет активной тренировки",
                        systemImage: "figure.strengthtraining.traditional")
                }
            }
            .background(Color(red: 0.035, green: 0.055, blue: 0.086))
            .navigationTitle("SportFit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") {
                        engine.pause()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDiscard = true } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Управление тренировкой", isPresented: $showDiscard) {
                Button("Завершить досрочно") { engine.earlyFinish() }
                Button("Удалить черновик", role: .destructive) {
                    engine.discard()
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Сохранённые результаты прошлых занятий не удаляются.")
            }
            .confirmationDialog("Причина пропуска", isPresented: $skipSheet) {
                ForEach(["Не подошло по самочувствию", "Слишком сложно",
                         "Недостаточно времени", "Нет инвентаря", "Другая причина"], id: \.self) { reason in
                    Button(reason) { engine.skip(reason: reason) }
                }
                Button("Отмена", role: .cancel) {}
            }
            .sheet(item: $editingSet) { actual in
                SetEditor(actual: actual, timed: current?.isTimed ?? false) { reps, kg, seconds in
                    engine.editSet(actual.id, reps: reps, weight: kg, seconds: seconds)
                }
            }
            .sheet(isPresented: $showOrder) {
                NavigationStack {
                    List {
                        ForEach(Array((draft?.movements ?? []).enumerated()), id: \.element.id) { index, movement in
                            HStack {
                                Text(movement.title)
                                Spacer()
                                Button { engine.reorder(from: index, to: index - 1) } label: { Image(systemName: "arrow.up") }
                                    .disabled(index == 0).accessibilityLabel("Переместить выше")
                                Button { engine.reorder(from: index, to: index + 1) } label: { Image(systemName: "arrow.down") }
                                    .disabled(index == (draft?.movements.count ?? 0) - 1).accessibilityLabel("Переместить ниже")
                            }.buttonStyle(.borderless)
                        }
                    }.navigationTitle("Порядок упражнений")
                        .toolbar { Button("Готово") { showOrder = false } }
                }
            }
            .interactiveDismissDisabled(draft?.phase != .paused && draft?.phase != .summary)
            .scrollDismissesKeyboard(.interactively)
            .onReceive(ticker) { now in
                currentSecond = now
                engine.tick()
            }
            .onChange(of: draft?.currentIndex) { _, _ in loadInputDefaults() }
            .onAppear { loadInputDefaults() }
            .alert("SportFit", isPresented: Binding(
                get: { engine.notice != nil },
                set: { if !$0 { engine.notice = nil } }
            )) {
                Button("Понятно") { engine.notice = nil }
            } message: {
                Text(engine.notice ?? "")
            }
        }
        .tint(.mint)
    }

    @ViewBuilder private func phaseContent(draft: WorkoutDraft, movement: WorkoutMovement) -> some View {
        switch draft.phase {
        case .prepare:
            Text("Подготовься к выполнению упражнения")
                .foregroundStyle(.secondary)
            Button("Начать упражнение") { engine.begin() }
                .buttonStyle(SportPrimaryButton())
            movementControls()
        case .active:
            Text(timeString(draft.activeSeconds(now: currentSecond)))
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
            if movement.isTimed {
                VStack(alignment: .leading) {
                    Text("Фактическая длительность, сек").font(.caption)
                    TextField("Секунды", text: $secondsText).keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Повторений").font(.caption)
                        TextField("Количество", text: $repsText).keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading) {
                        Text("Вес, кг").font(.caption)
                        TextField("Вес", text: $weightText).keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            Text("Количество подходов корректируй по своему согласованному плану и самочувствию.")
                .font(.caption).foregroundStyle(.secondary)
            Button("✓ Подход выполнен") {
                let reps = Int(repsText)
                let kg = Double(weightText.replacingOccurrences(of: ",", with: "."))
                engine.complete(reps: movement.isTimed ? nil : reps,
                                weight: movement.isTimed ? nil : kg,
                                seconds: movement.isTimed ? Int(secondsText) : nil)
            }.buttonStyle(SportPrimaryButton())
            Button(draft.currentIndex == draft.movements.count - 1 ? "Завершить занятие" : "Следующее упражнение") {
                engine.nextExercise()
            }
            .buttonStyle(.bordered)
            HStack {
                Button("Пауза") { engine.pause() }
                Spacer()
                Button("Пропустить") { skipSheet = true }
            }.font(.subheadline).foregroundStyle(.mint)
            movementControls()
        case .rest:
            Text("Отдых").font(.headline)
            Text(timeString(engine.restRemaining()))
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack {
                ForEach([15, 30, 60], id: \.self) { value in
                    Button("+\(value) сек") { engine.extendRest(value) }
                        .buttonStyle(.bordered)
                }
            }
            Button("Добавить ещё подход") { engine.addAnotherSet() }
                .buttonStyle(.bordered)
            Button(draft.currentIndex == draft.movements.count - 1 ? "Завершить занятие" : "Следующее упражнение") { engine.nextExercise() }
                .buttonStyle(SportPrimaryButton())
            Button("Пауза") { engine.pause() }.foregroundStyle(.mint)
        case .paused:
            Text("Тренировка приостановлена").font(.title3.bold())
            Text("Выполненные подходы и черновик сохранены.")
                .foregroundStyle(.secondary)
            Button("▶ Продолжить") { engine.resume() }
                .buttonStyle(SportPrimaryButton())
            movementControls()
        case .summary:
            Label(draft.finishedEarly || draft.movements.contains(where: { $0.skipped || $0.sets.isEmpty }) ? "Частичное занятие" : "Итог занятия", systemImage: "checkmark.seal.fill")
                .font(.title2.bold()).foregroundStyle(.mint)
            Text("\(draft.completedSetCount) подходов · \(draft.skippedCount) пропущено")
                .foregroundStyle(.secondary)
            Text("Время занятия без пауз: \(timeString(draft.activeSeconds(now: currentSecond)))")
            Text("Как ты себя чувствуешь?").font(.headline)
            Picker("Самочувствие", selection: $feeling) {
                ForEach(["Сложно", "Как раз", "Легко"], id: \.self) { option in
                    Text(option)
                }
            }.pickerStyle(.segmented)
            Button("Сохранить результат") {
                if engine.finish(feeling: feeling) != nil {
                    dismiss()
                }
            }.buttonStyle(SportPrimaryButton())
        }
    }

    private func movementControls() -> some View {
        HStack {
            Button { engine.move(by: -1) } label: {
                Label("Назад", systemImage: "chevron.left")
            }
            Spacer()
            Button { engine.move(by: 1) } label: {
                Label("Далее", systemImage: "chevron.right")
            }
        }
        .font(.subheadline)
        .disabled(draft == nil)
        .padding(.top, 6)
    }

    private func loadInputDefaults() {
        guard let movement = current else { return }
        let fromSource = movement.target
        let nums = fromSource.split(whereSeparator: { !$0.isNumber })
        let first = nums.first.flatMap { Int($0) }
        repsText = first.map { String($0) } ?? ""
        secondsText = first.map { String(max(1, fromSource.contains("мин") ? $0 * 60 : $0)) } ?? ""
        weightText = "0"
    }

    private func phaseTitle(_ phase: TrainingPhase) -> String {
        switch phase {
        case .prepare: return "Подготовка"
        case .active: return "Выполнение"
        case .rest: return "Отдых"
        case .paused: return "Пауза"
        case .summary: return "Итог"
        }
    }
    private func timeString(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct SportPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(Color.mint.opacity(configuration.isPressed ? 0.65 : 1),
                        in: RoundedRectangle(cornerRadius: 15))
            .foregroundStyle(Color.black)
    }
}

private struct SetEditor: View {
    let actual: ActualSet
    let timed: Bool
    let save: (Int?, Double?, Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reps = ""
    @State private var kg = ""
    @State private var seconds = ""
    @State private var invalid = false
    var body: some View {
        NavigationStack {
            Form {
                if timed { TextField("Секунды", text: $seconds).keyboardType(.numberPad) }
                else {
                    TextField("Повторы", text: $reps).keyboardType(.numberPad)
                    TextField("Вес, кг", text: $kg).keyboardType(.decimalPad)
                }
                if invalid { Text("Проверь введённые значения").foregroundStyle(.red) }
                Button("Сохранить") {
                    let weight = Double(kg.replacingOccurrences(of: ",", with: "."))
                    guard timed ? Int(seconds).map({ (1...3600).contains($0) }) == true :
                        (Int(reps).map({ (1...300).contains($0) }) == true && weight.map({ $0.isFinite && (0...250).contains($0) }) == true) else {
                        invalid = true; return
                    }
                    save(Int(reps), weight, Int(seconds)); dismiss()
                }
            }.navigationTitle("Исправить подход")
                .toolbar { Button("Отмена") { dismiss() } }
                .onAppear {
                    reps = actual.reps.map { String($0) } ?? ""
                    kg = actual.weightKg.map { String($0) } ?? ""
                    seconds = actual.seconds.map { String($0) } ?? ""
                }
        }
    }
}
