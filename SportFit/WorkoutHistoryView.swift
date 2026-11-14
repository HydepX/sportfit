import SwiftUI

struct WorkoutHistoryView: View {
    @EnvironmentObject private var engine: WorkoutEngine
    @EnvironmentObject private var store: FitnessStore
    @EnvironmentObject private var journal: JournalStore
    @State private var period = HistoryPeriod.week
    @State private var start = Date()
    @State private var end = Date()
    private var filter: HistoryFilter { HistoryFilter(period: period, start: start, end: end) }
    private var workouts: [WorkoutResult] {
        engine.history.filter { filter.contains($0.finishedAt) }.sorted { $0.finishedAt > $1.finishedAt }
    }
    private var legacyDates: [String] {
        Set(store.completedSets.map(\.date)).filter { SportDate.from($0).map { filter.contains($0) } ?? false }.sorted(by: >)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Период тренировок", selection: $period) {
                ForEach(HistoryPeriod.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
            if period == .custom {
                DatePicker("С", selection: $start, in: ...Date(), displayedComponents: .date)
                DatePicker("По", selection: $end, in: start...max(start, Date()), displayedComponents: .date)
                Text("Показаны оба выбранных дня включительно").font(.caption).foregroundStyle(.secondary)
            }
            Text("Занятий: \(workouts.count) · подходов: \(workouts.reduce(0) { $0 + $1.totalSets })")
                .font(.subheadline).foregroundStyle(.secondary)
            if workouts.isEmpty && legacyDates.isEmpty {
                Text("За этот период тренировок нет. Можно выбрать другие даты или раскрыть всю историю.")
                    .foregroundStyle(.secondary)
            }
            ForEach(journal.data.retiredDrafts ?? []) { draft in
                NavigationLink("Незавершённая прежняя тренировка · " + draft.title) { RetiredDraftScreen(draft: draft) }
            }
            ForEach(workouts) { workout in
                NavigationLink { WorkoutResultScreen(result: workout) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(workout.finishedAt, format: .dateTime.day().month(.wide).year()).font(.headline)
                        Text(workout.title).font(.subheadline)
                        Text("\(workout.totalSets) подходов · \(workout.durationSeconds / 60) мин · \(workout.completionLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                        Label("Раскрыть тренировку", systemImage: "chevron.right").font(.subheadline).foregroundStyle(.mint)
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
            ForEach(legacyDates, id: \.self) { date in
                DisclosureGroup("\(date) · старые отметки") {
                    ForEach(store.completedSets.filter { $0.date == date }) { item in
                        Text(store.exercise(item.exerciseId)?.title ?? item.exerciseId)
                    }
                    Text("Эти старые записи не содержат повторов, веса и времени; восстановить их автоматически нельзя.").font(.caption)
                }
            }
            if period != .all {
                Button("Показать более ранние тренировки") { period = .all }.buttonStyle(.bordered)
            }
        }.onChange(of: start) { _, value in
            if end < value { end = value }
        }
    }
}
