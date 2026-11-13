import Foundation
import SwiftUI

@MainActor final class JournalStore: ObservableObject {
    @Published private(set) var data = JournalData()
    @Published var error: String?
    private(set) var healthy = true
    var canExport: Bool { healthy && LocalFiles.recoveryError == nil }
    let directory: URL
    private var file: URL { directory.appendingPathComponent("journal.v1.json") }
    init(directory: URL = LocalFiles.directory) { self.directory = directory; reload() }
    func reload() {
        healthy = true
        guard FileManager.default.fileExists(atPath: file.path) else { data = JournalData(); return }
        do {
            let loaded = try JSONDecoder().decode(JournalData.self, from: Data(contentsOf: file))
            try loaded.validate(); data = loaded; error = nil
        } catch { healthy = false; self.error = "Дневник не прочитан; исходный файл сохранён: \(error.localizedDescription)" }
    }
    @discardableResult func change(_ update: (inout JournalData) -> Void) -> Bool {
        guard canExport else { error = "Восстанови дневник из копии перед изменением"; return false }
        var next = data; update(&next)
        do {
            try next.validate()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            data = next; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func saveActivity(_ entry: ActivityEntry) -> Bool {
        if data.activity.contains(where: { $0.id != entry.id && $0.date == entry.date && $0.metric == entry.metric && $0.value == entry.value }) {
            error = "Такое измерение уже сохранено"; return false
        }
        return change { data in
            if let index = data.activity.firstIndex(where: { $0.id == entry.id }) { data.activity[index] = entry }
            else { data.activity.append(entry) }
        }
    }
    func saveGoal(_ goal: QuarterGoal) -> Bool {
        change { data in
            if let index = data.goals.firstIndex(where: { $0.id == goal.id }) { data.goals[index] = goal }
            else { data.goals.append(goal) }
        }
    }
    func saveNote(_ note: DayNote) -> Bool {
        change { data in
            if let index = data.notes.firstIndex(where: { $0.id == note.id }) { data.notes[index] = note }
            else { data.notes.append(note) }
        }
    }
    func saveReport(_ report: QuarterReport) -> Bool {
        // Exporting a stored snapshot again must not create another report.
        if data.reports.contains(where: { $0.id == report.id }) { return true }
        return change { $0.reports.append(report) }
    }
}
