import SwiftUI

@main
struct SportFitApp: App {
    @StateObject private var store = FitnessStore()
    @StateObject private var engine = WorkoutEngine()
    @StateObject private var measurements = MeasurementsStore()
    @StateObject private var profile = ProfileStore()
    @StateObject private var journal = JournalStore()
    @StateObject private var reminders = ReminderService()
    @StateObject private var imported = HealthImportStore()

    init() {
        // Replace the bundled plan before the other stores read runs and drafts.
        let preparedStore = FitnessStore()
        _store = StateObject(wrappedValue: preparedStore)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(measurements)
                .environmentObject(profile)
                .environmentObject(journal)
                .environmentObject(reminders)
                .environmentObject(imported)
                .preferredColorScheme(.dark)
        }
    }
}
