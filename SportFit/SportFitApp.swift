import SwiftUI

@main
struct SportFitApp: App {
    @StateObject private var store = FitnessStore()
    @StateObject private var engine = WorkoutEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }
}
