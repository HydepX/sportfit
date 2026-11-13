import SwiftUI
import UIKit

struct WorkoutPlayer: View {
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var engine: WorkoutEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingSet: ActualSet?
    @State private var resumeAfterEditing = false
    @State private var showTechnique = false
    @State private var showOrder = false
    @State private var restart = false
    @State private var feeling = "Как раз"
    @State private var skipSheet = false
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private let background = Color(red: 0.035, green: 0.055, blue: 0.086)
    private var draft: WorkoutDraft? { engine.draft }
    private var current: WorkoutMovement? {
        guard let d = draft, d.movements.indices.contains(d.currentIndex) else { return nil }
        return d.movements[d.currentIndex]
    }
    private var navigationContent: some View {
            content
                .background(background)
                .safeAreaInset(edge: .bottom) { if let draft { controls(draft).padding().background(background) } }
                .navigationTitle("SportFit").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { engine.pause(); dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { WorkoutActions(closePlayer: { dismiss() }) } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel("Управление тренировкой").accessibilityIdentifier("workout-actions")
                    }
                }

    }
    private var presentedContent: some View {
        navigationContent
                .confirmationDialog("Причина пропуска", isPresented: $skipSheet) {
                    ForEach(["Не подошло по самочувствию", "Слишком сложно", "Недостаточно времени", "Нет инвентаря", "Другая причина"], id: \.self) { reason in
                        Button(reason) { engine.skip(reason: reason) }
                    }
                    Button("Отмена", role: .cancel) { engine.resume() }
                }
                .confirmationDialog("Повторить подход заново?", isPresented: $restart) {
                    Button("Повторить подход") { engine.restartCurrentSet() }
                    Button("Отмена", role: .cancel) { engine.resume() }
                } message: { Text("Последний результат этого подхода в черновике будет заменён новым выполнением. Остальные подходы сохранятся.") }
                .sheet(item: $editingSet, onDismiss: finishEditing) { actual in
                    SetEditor(actual: actual, timed: actual.seconds != nil) { reps, kg, seconds in
                        if engine.draft?.movements.contains(where: { $0.sets.contains(where: { $0.id == actual.id }) }) == true {
                            engine.editSet(actual.id, reps: reps, weight: kg, seconds: seconds)
                        } else { engine.complete(reps: reps, weight: kg, seconds: seconds) }
                    }
                }
                .sheet(isPresented: $showTechnique) {
                    NavigationStack {
                        if let current, let exercise = store.exercise(current.exerciseId) {
                            ExerciseDetailScreen(exercise: exercise).toolbar { Button("Готово") { showTechnique = false } }
                        }
                    }
                }
                .sheet(isPresented: $showOrder) { orderScreen }

    }
    var body: some View {
        NavigationStack {
            presentedContent
                .interactiveDismissDisabled(draft?.phase != .paused && draft?.phase != .summary)
                .onReceive(ticker) { _ in if scenePhase == .active { engine.tick() } }
                .onChange(of: scenePhase) { _, phase in if phase == .background { engine.suspendAutoplay() } }
                .onAppear { engine.enableGuidedMode() }
                .onChange(of: draft?.phase, initial: true) { _, phase in UIApplication.shared.isIdleTimerDisabled = phase == .active || phase == .rest }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
                .alert("SportFit", isPresented: Binding(get: { engine.notice != nil }, set: { if !$0 { engine.notice = nil } })) {
                    Button("Понятно") { engine.notice = nil }
                } message: { Text(engine.notice ?? "") }
        }.tint(.mint)
    }
    @ViewBuilder private var content: some View {
        if let draft, let movement = current {
            ScrollView {
                VStack(spacing: 18) {
                    if draft.phase == .summary { summary(draft) }
                    else {
                        HStack {
                            Text("Упражнение \(draft.currentIndex + 1) из \(draft.movements.count)")
                            Spacer()
                            Text("Подход \(movement.sets.count + (draft.phase == .rest || draft.pausedPhase == .rest ? 0 : 1)) из \(movement.prescription?.sets ?? 1)")
                        }.font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: Double(draft.currentIndex), total: Double(max(1, draft.movements.count))).tint(.mint)
                        if draft.phase == .rest { rest(draft, movement) }
                        else if draft.phase == .paused { paused(draft, movement) }
                        else { exercise(draft, movement) }
                    }
                }.padding(18)
            }
        } else { ContentUnavailableView("Нет активной тренировки", systemImage: "figure.strengthtraining.traditional") }
    }
    private func exercise(_ draft: WorkoutDraft, _ movement: WorkoutMovement) -> some View {
        VStack(spacing: 16) {
            Text(movement.title).font(.title2.bold()).multilineTextAlignment(.center).accessibilityIdentifier("player-exercise-title")
            ExerciseMediaView(exerciseId: movement.exerciseId).id(movement.id)
            Text("По плану: " + movement.target).foregroundStyle(.secondary)
            if draft.phase == .active {
                if movement.isTimed { PlayerClock(resting: false) }
                else { Text(movement.plannedReps.map { "× \($0)" } ?? "В своём темпе").font(.system(size: 64, weight: .bold, design: .rounded)).accessibilityIdentifier("planned-reps") }
                Text(movement.isTimed ? "После отсчёта откроется отдых" : "Когда закончишь подход, нажми «Выполнено»").font(.footnote).foregroundStyle(.secondary)
                Button("Начать подход заново") { engine.restartCurrentSet() }.accessibilityIdentifier("restart-active-set")
            } else if movement.prescription?.requiresClearance == true && movement.clearanceConfirmed != true {
                Text(movement.prescription?.clearanceNote ?? "Нужно разрешение врача").foregroundStyle(.yellow)
            }
            if let load = movement.prescription?.load { Text(load).font(.footnote).foregroundStyle(.yellow) }
            if let progression = movement.prescription?.progression { Text(progression).font(.footnote).foregroundStyle(.secondary) }
            if movement.sourceId != movement.exerciseId { Text("Щадящая замена из программы: \(movement.sourceId) → \(movement.exerciseId)").font(.footnote) }
            Button("Посмотреть технику") { engine.pause(); showTechnique = true }
            Button("Пропустить упражнение") { engine.pause(); skipSheet = true }.font(.footnote)
            if draft.phase == .prepare { Button("Порядок упражнений") { showOrder = true } }
        }
    }
    private func rest(_ draft: WorkoutDraft, _ movement: WorkoutMovement) -> some View {
        VStack(spacing: 18) {
            HStack { Image(systemName: "cup.and.saucer.fill"); Text("Отдых").accessibilityIdentifier("rest-screen") }.font(.title.bold())
            PlayerClock(resting: true)
            HStack { ForEach([15, 30, 60], id: \.self) { seconds in
                Button("+\(seconds) сек") { engine.extendRest(seconds) }.buttonStyle(.bordered).accessibilityIdentifier("extend-rest-\(seconds)")
            } }
            if draft.restEndsAt == nil {
                Text((movement.prescription?.restSeconds ?? movement.sourceRestSeconds) == 0
                     ? "По плану отдых — 0 секунд. Перейди дальше, когда будешь готов."
                     : "Отдых в программе не указан. Перейди дальше, когда будешь готов.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let actual = movement.sets.last {
                Text(movement.title).font(.headline).multilineTextAlignment(.center)
                Text(actualLabel(actual)).foregroundStyle(.secondary).accessibilityIdentifier("rest-result")
                Button("Изменить результат") { edit(actual) }.accessibilityIdentifier("edit-rest-result")
                Button("Повторить этот подход") { engine.pause(); restart = true }.font(.footnote)
            }
            Divider()
            if let next = nextMovement(draft) {
                Text(draft.restAfterLastSet ? "Следующее упражнение" : "Следующий подход").font(.caption).foregroundStyle(.secondary)
                Text(next.title).font(.title3.bold()).multilineTextAlignment(.center)
                Text(next.target).foregroundStyle(.secondary)
                ExerciseMediaView(exerciseId: next.exerciseId).id(next.id)
            } else { Text("Дальше — итоги занятия").font(.headline) }
        }.padding().frame(maxWidth: .infinity).background(.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
    }
    private func paused(_ draft: WorkoutDraft, _ movement: WorkoutMovement) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "pause.circle.fill").font(.system(size: 64)).foregroundStyle(.mint)
            Text("Тренировка приостановлена").font(.title2.bold())
            Text(movement.title).font(.headline).multilineTextAlignment(.center)
            if draft.pausedPhase == .rest { PlayerClock(resting: true) }
            else if movement.isTimed { PlayerClock(resting: false) }
            Text("Таймер остановлен. Результаты и черновик сохранены.").font(.footnote).foregroundStyle(.secondary)
            ForEach(movement.sets) { actual in Button("Изменить: " + actualLabel(actual)) { edit(actual) } }
        }
    }
    @ViewBuilder private func controls(_ draft: WorkoutDraft) -> some View {
        switch draft.phase {
        case .active:
            HStack(spacing: 12) {
                Button { engine.pause() } label: { Label("Пауза", systemImage: "pause.fill") }.buttonStyle(.bordered).accessibilityIdentifier("pause-workout")
                Button(current?.isTimed == true ? "Закончить раньше" : "Выполнено") { finishSet() }.buttonStyle(SportPrimaryButton()).accessibilityIdentifier("complete-current-set")
            }
        case .rest:
            HStack(spacing: 12) {
                Button { engine.pause() } label: { Label("Пауза", systemImage: "pause.fill") }.buttonStyle(.bordered)
                Button(draft.restAfterLastSet ? "Дальше" : "Следующий подход") { engine.continueAfterRest() }.buttonStyle(SportPrimaryButton()).accessibilityIdentifier("continue-after-rest")
            }
        case .paused:
            Button("▶ Продолжить") { engine.resume() }.buttonStyle(SportPrimaryButton()).accessibilityIdentifier("resume-workout")
        case .prepare:
            Button(current?.prescription?.requiresClearance == true && current?.clearanceConfirmed != true ? "Разрешение врача есть — начать" : "Начать упражнение") {
                engine.begin(clearanceConfirmed: true)
            }.buttonStyle(SportPrimaryButton())
        case .summary:
            Button("Сохранить результат") { if engine.finish(feeling: feeling) != nil { dismiss() } }.buttonStyle(SportPrimaryButton())
        }
    }
    private func summary(_ draft: WorkoutDraft) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Итоги занятия", systemImage: "checkmark.seal.fill").font(.title.bold())
            Text("\(draft.completedSetCount) подходов · \(draft.skippedCount) пропущено")
            Text("Время без пауз: \(draft.activeSeconds() / 60) мин")
            Text("Проверь результаты перед сохранением. Исправления попадут в статистику; назначения программы останутся прежними.").font(.footnote).foregroundStyle(.secondary)
            Picker("Самочувствие", selection: $feeling) { ForEach(["Сложно", "Как раз", "Легко"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            ForEach(draft.movements) { movement in
                VStack(alignment: .leading, spacing: 10) {
                    Text(movement.title).font(.headline)
                    Text("План: " + movement.target).font(.caption).foregroundStyle(.secondary)
                    if movement.skipped { Text("Пропущено: " + (movement.skipReason ?? "Причина не указана")).font(.caption) }
                    ForEach(movement.sets) { actual in
                        HStack { Text(actualLabel(actual)); Spacer(); Button("Изменить") { edit(actual) }.accessibilityIdentifier("edit-summary-set") }
                    }
                    if movement.sets.isEmpty { Text("Подходы не записаны").font(.caption).foregroundStyle(.secondary) }
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private var orderScreen: some View {
        NavigationStack {
            List { ForEach(Array((draft?.movements ?? []).enumerated()), id: \.element.id) { index, movement in
                HStack {
                    Text(movement.title); Spacer()
                    Button { engine.reorder(from: index, to: index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).accessibilityLabel("Переместить выше")
                    Button { engine.reorder(from: index, to: index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == (draft?.movements.count ?? 0) - 1).accessibilityLabel("Переместить ниже")
                }.buttonStyle(.borderless)
            } }.navigationTitle("Порядок упражнений").toolbar { Button("Готово") { showOrder = false } }
        }
    }
    private func nextMovement(_ draft: WorkoutDraft) -> WorkoutMovement? {
        let index = draft.restAfterLastSet ? draft.currentIndex + 1 : draft.currentIndex
        return draft.movements.indices.contains(index) ? draft.movements[index] : nil
    }
    private func actualLabel(_ actual: ActualSet) -> String {
        actual.seconds.map { "Выполнено: \($0) сек" } ?? "Выполнено: \(actual.reps ?? 0) × \((actual.weightKg ?? 0).formatted()) кг"
    }
    private func edit(_ actual: ActualSet) {
        resumeAfterEditing = draft?.phase == .rest || draft?.phase == .active
        if resumeAfterEditing { engine.pause() }
        editingSet = actual
    }
    private func finishEditing() { if resumeAfterEditing { engine.resume() }; resumeAfterEditing = false }
    private func finishSet() {
        guard let movement = current else { return }
        if movement.isTimed || movement.plannedReps == nil {
            let elapsed = movement.plannedSeconds.map { max(1, $0 - (engine.exerciseRemaining() ?? $0)) }
            let actual = ActualSet(reps: movement.isTimed ? nil : movement.plannedReps, weightKg: movement.isTimed ? nil : 0,
                                   seconds: movement.isTimed ? (elapsed ?? 1) : nil, completedAt: Date())
            edit(actual)
        } else { engine.completePlanned() }
    }
}

private struct PlayerClock: View {
    @EnvironmentObject private var engine: WorkoutEngine
    let resting: Bool
    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    var body: some View {
        let draft = engine.draft
        let seconds = resting ? (draft?.phase == .paused ? draft?.restSecondsLeft ?? 0 : engine.restRemaining(now: now)) : engine.exerciseRemaining(now: now)
        Text(seconds.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "Без таймера")
            .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
            .accessibilityIdentifier(resting ? "rest-countdown" : "exercise-countdown")
            .onReceive(ticker) { now = $0 }
    }
}

/// A regular navigation screen keeps actions accessible without a transient popover.
private struct WorkoutActions: View {
    @EnvironmentObject private var engine: WorkoutEngine
    @Environment(\.dismiss) private var dismiss
    let closePlayer: () -> Void
    @State private var confirmDiscard = false
    var body: some View {
        List {
            Button("Завершить досрочно") {
                engine.earlyFinish()
                dismiss()
            }.accessibilityIdentifier("finish-early")
            Button("Удалить черновик", role: .destructive) { confirmDiscard = true }
            Text("Досрочное завершение открывает итог: результат нужно сохранить отдельно. Сохранённые результаты прошлых занятий не удаляются.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Действия")
        .onAppear { engine.pause() }
        .alert("Удалить незавершённую тренировку?", isPresented: $confirmDiscard) {
            Button("Удалить черновик", role: .destructive) {
                engine.discard()
                closePlayer()
            }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Сохранённые результаты прошлых занятий не удаляются.") }
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
                if timed { TextField("Секунды", text: $seconds).keyboardType(.numberPad).accessibilityIdentifier("set-seconds") }
                else {
                    TextField("Повторы", text: $reps).keyboardType(.numberPad).accessibilityIdentifier("set-reps")
                    TextField("Вес, кг", text: $kg).keyboardType(.decimalPad).accessibilityIdentifier("set-weight")
                }
                if invalid { Text("Проверь введённые значения").foregroundStyle(.red) }
                Button("Сохранить") {
                    let weight = Double(kg.replacingOccurrences(of: ",", with: "."))
                    guard timed ? Int(seconds).map({ (1...3600).contains($0) }) == true :
                        (Int(reps).map({ (1...300).contains($0) }) == true && weight.map({ $0.isFinite && (0...250).contains($0) }) == true) else {
                        invalid = true; return
                    }
                    save(Int(reps), weight, Int(seconds)); dismiss()
                }.accessibilityIdentifier("save-set-edit")
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
