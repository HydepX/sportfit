import SwiftUI
import UniformTypeIdentifiers

private enum Palette {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.086)
    static let panel = Color(red: 0.08, green: 0.12, blue: 0.17)
    static let accent = Color(red: 0.65, green: 0.95, blue: 0.42)
}

struct RootView: View {
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var engine: WorkoutEngine
    @EnvironmentObject private var measurements: MeasurementsStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var reminders: ReminderService
    @EnvironmentObject private var imported: HealthImportStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    @State private var progressDestination: String?
    @State private var dataEpoch = UUID()

    var body: some View {
        TabView(selection: $selection) {
            HomeScreen(onWorkout: { selection = 2 })
                .tabItem { Label("Главная", systemImage: "house") }.tag(0)
            ProgramRunScreen(title: "План")
                .tabItem { Label("План", systemImage: "calendar") }.tag(1)
            ProgramRunScreen(title: "Тренировка")
                .tabItem { Label("Тренировка", systemImage: "play.circle.fill") }.tag(2)
            ProgressScreen(destination: $progressDestination)
                .tabItem { Label("Прогресс", systemImage: "chart.xyaxis.line") }.tag(3)
            SettingsScreen()
                .tabItem { Label("Профиль", systemImage: "person.crop.circle") }.tag(4)
        }
        .id(dataEpoch)
        .tint(Palette.accent)
        .background(Palette.background)
        .task { await synchronize() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await synchronize() } } }
        .onReceive(profile.$runs) { _ in Task { await synchronize() } }
        .onReceive(engine.$draft) { _ in Task { await synchronize() } }
        .onReceive(journal.$data) { _ in Task { await synchronize() } }
        .onReceive(measurements.$entries) { _ in Task { await synchronize() } }
        .onReceive(NotificationCenter.default.publisher(for: .sportfitDataRestored)) { notification in
            guard let folder = notification.object as? URL, folder == store.directory else { return }
            selection = 0; progressDestination = nil; dataEpoch = UUID()
            store.message = "Данные восстановлены. Напоминания выключены до явного включения."
        }
        .onChange(of: reminders.destination, initial: true) { _, target in
            guard let target else { return }
            if target == "plan" { selection = 1 }
            else { selection = 3; progressDestination = target == "progress" ? nil : target }
            reminders.destination = nil
        }
        .alert("SportFit", isPresented: Binding(
            get: { store.message != nil },
            set: { if !$0 { store.message = nil } }
        )) {
            Button("OK") { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
    }
    private func synchronize() async {
        if journal.canExport && engine.canExport && measurements.canExport {
            for run in profile.runs where run.closedAt != nil {
                let scope = "run:" + run.id.uuidString
                if !journal.data.reports.contains(where: { $0.scope == scope && $0.isFinal }) {
                    let report = QuarterReport.make(title: run.title, scope: scope, start: SportDate.calendar.startOfDay(for: run.startedAt), end: run.closedAt!, run: run,
                        history: engine.history, measurements: measurements.entries, xml: imported.records, journal: journal.data, name: profile.profile.name, privacy: .full)
                    _ = journal.saveReport(report)
                }
            }
        }
        await reminders.refresh(settings: journal.data.reminders, run: profile.activeRun ?? profile.runs.last,
            draft: engine.draft, measurements: measurements.entries, history: engine.history)
        do { try BackupVault.automatic(engine: engine, measurements: measurements, store: store, profile: profile, journal: journal) }
        catch { journal.error = "Автоматическая копия не создана: \(error.localizedDescription)" }
    }
}

private struct Panel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 19))
    }
}

struct HomeScreen: View {
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var measurements: MeasurementsStore
    @EnvironmentObject private var profile: ProfileStore
    let onWorkout: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("МОЯ ФОРМА").font(.caption2.bold()).tracking(2).foregroundStyle(Palette.accent)
                    Text("Обзор").font(.largeTitle.bold())
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Личная программа", systemImage: "person.crop.circle").font(.headline)
                            Text(profile.activeRun.map { "\($0.title) · закрыто \($0.completedDayCount) из \($0.dayCount) дней" } ?? "Выбери уровень и проходи дни в своём темпе")
                                .foregroundStyle(.secondary).font(.subheadline)
                            if let program = profile.activeRun?.program ?? store.program {
                                Text("\(program.phases.count) этапа · индивидуальный план").font(.title3.bold())
                            } else {
                                Text("Импортируй план тренировок в настройках")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let latest = measurements.latest {
                        Panel {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Последний замер").font(.headline)
                                Text("\(latest.weightKg.formatted(.number.precision(.fractionLength(1)))) кг")
                                    .font(.title.bold())
                                Text(latest.measuredAt, format: .dateTime.day().month().year())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Ближайшая тренировка").font(.headline)
                            if let run = profile.activeRun, let index = run.currentDay {
                                Text("День \(index + 1)").font(.subheadline)
                                Text(run.workout(on: index)?.name ?? "Отдых").font(.title3.bold())
                                Text("После закрытия дня откроется следующий")
                                    .foregroundStyle(.secondary).font(.subheadline)
                            } else {
                                Text("Начни новый уровень или закрой пройденный")
                                    .foregroundStyle(.secondary)
                            }
                            Button(action: onWorkout) {
                                Text("Открыть тренировку").fontWeight(.bold)
                                    .frame(maxWidth: .infinity).padding(13)
                            }
                            .buttonStyle(.plain).background(Palette.accent, in: RoundedRectangle(cornerRadius: 13))
                            .foregroundStyle(.black)
                        }
                    }
                    Text("Данные сохраняются локально. Перерыв не создаёт пропусков в программе.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .background(Palette.background)
        }
    }
}

struct LibraryScreen: View {
    @EnvironmentObject private var store: FitnessStore
    @State private var query = ""
    @State private var selectedGroup = "Все"

    private var groups: [String] {
        ["Все"] + Array(Set(store.catalog?.exercises.map(\.primaryGroup) ?? [])).sorted()
    }
    private var filtered: [Exercise] {
        (store.catalog?.exercises ?? []).filter {
            (selectedGroup == "Все" || $0.primaryGroup == selectedGroup)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.catalog == nil {
                    ContentUnavailableView("Библиотека не загружена",
                        systemImage: "books.vertical",
                        description: Text("Добавь exercises.v1.json через Настройки."))
                } else {
                    List(filtered) { exercise in
                        NavigationLink(value: exercise) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(exercise.title).font(.headline)
                                Text("\(exercise.primaryGroup) · \(exercise.equipment.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                        .listRowBackground(Palette.panel)
                    }
                    .scrollContentBackground(.hidden)
                    .navigationDestination(for: Exercise.self) { ExerciseDetailScreen(exercise: $0) }
                    .searchable(text: $query, prompt: "Поиск упражнения")
                    .safeAreaInset(edge: .top) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(groups, id: \.self) { group in
                                    Button(group) { selectedGroup = group }
                                        .font(.caption.bold())
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(selectedGroup == group ? Palette.accent : Palette.panel,
                                                    in: Capsule())
                                        .foregroundStyle(selectedGroup == group ? .black : .white)
                                }
                            }.padding(.horizontal)
                        }.padding(.vertical, 8).background(Palette.background)
                    }
                }
            }
            .navigationTitle("Упражнения")
            .background(Palette.background)
        }
    }
}

struct ExerciseDetailScreen: View {
    let exercise: Exercise

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ExerciseMediaView(exerciseId: exercise.id)
                Text(exercise.primaryGroup).foregroundStyle(Palette.accent)
                Text(exercise.description)
                Text("Инвентарь: " + exercise.equipment.joined(separator: ", "))
                if let rest = exercise.suggestedRestFromSource {
                    Text("Отдых из источника: " + rest).font(.subheadline)
                }
                if !exercise.safetyFlag.isEmpty {
                    Panel {
                        Label(exercise.safetyFlag, systemImage: "exclamationmark.shield")
                            .foregroundStyle(.yellow).font(.headline)
                        if let note = exercise.safetyNote, !note.isEmpty {
                            Text(note).font(.subheadline)
                        }
                    }
                }
                Text("Техника выполнения").font(.title3.bold())
                ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").foregroundStyle(Palette.accent).fontWeight(.bold)
                        Text(instruction)
                    }
                }
                if exercise.commonMistakesReviewStatus == "approved", let mistakes = exercise.commonMistakesDraft, !mistakes.isEmpty {
                    Text("На что обратить внимание").font(.title3.bold())
                    ForEach(mistakes, id: \.self) { Text("• " + $0) }
                }
                if let reps = exercise.suggestedRepsFromSource {
                    Text("Ориентир из источника: \(reps)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let reference = exercise.originalExternalReference,
                   let url = URL(string: reference) {
                    Link("Открыть справочную ссылку", destination: url)
                        .font(.subheadline).foregroundStyle(Palette.accent)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .background(Palette.background)
        .navigationTitle(exercise.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
