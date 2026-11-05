import SwiftUI

@main
struct SportFitApp: App {
    @StateObject private var store = FitnessStore()
    @StateObject private var engine = WorkoutEngine()
    @StateObject private var measurements = MeasurementsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(measurements)
                .preferredColorScheme(.dark)
        }
    }
}
