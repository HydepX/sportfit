import SwiftUI

@main
struct SportFitApp: App {
    @StateObject private var store = FitnessStore()
    @StateObject private var engine = WorkoutEngine()
    @StateObject private var measurements = MeasurementsStore()
    @StateObject private var profile = ProfileStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(measurements)
                .environmentObject(profile)
                .preferredColorScheme(.dark)
        }
    }
}
