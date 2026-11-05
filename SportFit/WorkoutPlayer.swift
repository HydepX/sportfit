import SwiftUI

struct WorkoutPlayer: View {
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var engine: WorkoutEngine
    @Environment(\.dismiss) private var dismiss
    @State private var repsText = "10"
    @State private var weightText = "0"
    @State private var secondsText = "40"
    @State private var feeling = "Как раз"
    @State private var skipReason = "Не подошло по самочувствию"
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

                            VStack(spacing: 10) {
                                Image(systemName: "figure.strengthtraining.traditional")
                                    .font(.system(size: 75)).foregroundStyle(.mint)
                                Text("Видео техники появится здесь")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).frame(height: 180)
                                .background(Color.white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 22))

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
            Button("Следующее упражнение") { engine.nextExercise() }
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
            Label("Тренировка завершена", systemImage: "checkmark.seal.fill")
                .font(.title2.bold()).foregroundStyle(.mint)
            Text("\(draft.completedSetCount) подходов · \(draft.skippedCount) пропущено")
                .foregroundStyle(.secondary)
            Text("Активное время: \(timeString(draft.activeSeconds(now: currentSecond)))")
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
        let first = nums.first.flatMap { Int($0) } ?? 10
        repsText = String(first)
        secondsText = String(max(1, fromSource.contains("мин") ? first * 60 : first))
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
