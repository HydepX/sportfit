import SwiftUI
import UniformTypeIdentifiers

struct CalendarScreen: View {
    @EnvironmentObject private var store: FitnessStore
    @State private var selectedDate = Date()

    private var currentWeekMonday: Date {
        let weekday = Calendar.current.component(.weekday, from: selectedDate)
        return Calendar.current.date(byAdding: .day, value: -((weekday + 5) % 7),
                                     to: Calendar.current.startOfDay(for: selectedDate)) ?? selectedDate
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let program = store.program {
                        HStack {
                            Button {
                                selectedDate = Calendar.current.date(byAdding: .day, value: -7, to: selectedDate) ?? selectedDate
                            } label: { Image(systemName: "chevron.left") }
                            Spacer()
                            if let week = store.weekNumber(for: selectedDate) {
                                VStack(spacing: 3) {
                                    Text("Неделя \(week) из 12").font(.headline)
                                    Text(store.phase(week: week)?.title ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Вне программы").font(.headline)
                            }
                            Spacer()
                            Button {
                                selectedDate = Calendar.current.date(byAdding: .day, value: 7, to: selectedDate) ?? selectedDate
                            } label: { Image(systemName: "chevron.right") }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)

                        HStack(spacing: 5) {
                            ForEach(0..<7, id: \.self) { index in
                                let day = Calendar.current.date(byAdding: .day, value: index, to: currentWeekMonday) ?? selectedDate
                                let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDate)
                                Button {
                                    selectedDate = day
                                } label: {
                                    VStack(spacing: 6) {
                                        Text(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"][index])
                                            .font(.caption2)
                                        Text("\(SportDate.dayNumber(day))").font(.headline)
                                        Circle()
                                            .fill(store.workout(on: day) == nil ? .clear : Color.mint)
                                            .frame(width: 5, height: 5)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(isSelected ? Color.mint.opacity(0.2) : Color.white.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13)
                                        .stroke(isSelected ? Color.mint : .clear))
                                }.buttonStyle(.plain)
                            }
                        }

                        Button("Сегодня") { selectedDate = Date() }
                            .font(.subheadline.bold()).foregroundStyle(.mint)
                        if let week = store.weekNumber(for: selectedDate),
                           let phase = store.phase(week: week) {
                            Text(phase.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let day = store.workout(on: selectedDate) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(day.name).font(.title2.bold())
                                Text("\(day.exerciseIds.count) упражнений, включая разминку и заминку")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text("Нажимай на упражнение, чтобы открыть технику. Отмечай завершённые подходы ниже.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                ForEach(Array(day.exerciseIds.enumerated()), id: \.offset) { index, id in
                                    WorkoutExerciseRow(index: index + 1, id: id, date: selectedDate)
                                    if index < day.exerciseIds.count - 1 { Divider() }
                                }
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("День восстановления").font(.title3.bold())
                                Text("Основная тренировка сегодня не запланирована.")
                                    .foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding().background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                        }
                        Text("Программа: \(program.startDate) — \(program.endDate)")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("План не загружен",
                            systemImage: "calendar",
                            description: Text("Импортируй program_12w.v1.json через Настройки."))
                    }
                }.padding(16)
            }
            .background(Color(red: 0.035, green: 0.055, blue: 0.086))
            .navigationTitle("Тренировка")
        }
    }
}

private struct WorkoutExerciseRow: View {
    @EnvironmentObject private var store: FitnessStore
    let index: Int
    let id: String
    let date: Date

    var body: some View {
        let completed = store.setCount(exerciseId: id, day: date)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(index)").font(.headline).foregroundStyle(.mint).frame(width: 25)
                if let exercise = store.exercise(id) {
                    NavigationLink(destination: ExerciseDetailScreen(exercise: exercise)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(exercise.title).font(.subheadline.bold())
                            Text(exercise.suggestedRepsFromSource ?? exercise.primaryGroup)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(.white)
                } else {
                    Text(id).font(.subheadline.bold())
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Button {
                    store.undoSet(exerciseId: id, day: date)
                } label: {
                    Image(systemName: "minus.circle").font(.title3)
                }.disabled(completed == 0)
                Text("Подходов отмечено: \(completed)")
                    .font(.caption).monospacedDigit()
                Button {
                    store.markSet(exerciseId: id, day: date)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
            }.tint(.mint).padding(.leading, 33)
        }.padding(.vertical, 7)
    }
}

struct ProgressScreen: View {
    @EnvironmentObject private var store: FitnessStore
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Журнал тренировок").font(.title2.bold())
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Отмеченные подходы").font(.subheadline).foregroundStyle(.secondary)
                        Text("\(store.completedSets.count)").font(.system(size: 45, weight: .bold))
                        Text("Сохранены локально на iPhone")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(Color.white.opacity(0.07),
                                               in: RoundedRectangle(cornerRadius: 20))
                    ForEach(Array(Dictionary(grouping: store.completedSets, by: \.date).keys.sorted().reversed()), id: \.self) { date in
                        let count = store.completedSets.filter { $0.date == date }.count
                        HStack {
                            Text(date)
                            Spacer()
                            Text("\(count) подходов").foregroundStyle(.mint)
                        }.padding().background(Color.white.opacity(0.07),
                                                in: RoundedRectangle(cornerRadius: 14))
                    }
                    Text("Графики веса, состава тела, активности и автоматическая синхронизация Apple Health появятся после проверки подписи HealthKit.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }.background(Color(red: 0.035, green: 0.055, blue: 0.086))
                .navigationTitle("Прогресс")
        }
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var store: FitnessStore
    @State private var importingCatalog = false
    @State private var importingProgram = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Данные квартальной программы") {
                    Label(store.catalog == nil ? "Каталог не загружен" : "Каталог: \(store.catalog?.exercises.count ?? 0) упражнений",
                          systemImage: "books.vertical")
                    Button("Импортировать exercises.v1.json") { importingCatalog = true }
                    Label(store.program == nil ? "План не загружен" : "12-недельный план загружен",
                          systemImage: "calendar")
                    Button("Импортировать program_12w.v1.json") { importingProgram = true }
                    Text("Импортируются распакованные JSON-файлы из BLOCK03_iOS_library_package. Не ZIP.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Apple Health") {
                    Label("Интеграция ещё не подключена", systemImage: "heart.text.square")
                    Text("Для доступа к данным Huawei через Apple Здоровье нужен HealthKit. Его проверим на устройстве после решения вопроса бесплатной подписи.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("О приложении") {
                    Text("SportFit · первая версия")
                    Text("Хранение: только на устройстве. Фото и видео упражнений будут добавлены позже.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.035, green: 0.055, blue: 0.086))
            .navigationTitle("Настройки")
            .fileImporter(isPresented: $importingCatalog,
                          allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.importJSON(from: url, kind: .catalog)
                }
            }
            .fileImporter(isPresented: $importingProgram,
                          allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.importJSON(from: url, kind: .program)
                }
            }
        }
    }
}
