// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SportFitCore",
    products: [.library(name: "SportFitCore", targets: ["SportFitCore"])],
    targets: [
        .target(name: "SportFitCore", path: "SportFit", exclude: [
            "Analytics.swift", "Backup.swift", "WorkoutDatabase.swift", "JournalStore.swift", "ReminderService.swift", "ReportScreens.swift", "InsightsScreens.swift", "StorageScreen.swift", "ExerciseMediaView.swift", "FitnessStore.swift",
            "Health.swift", "HealthService.swift", "HealthTrends.swift", "Measurements.swift", "Profile.swift", "RootView.swift", "SportFitApp.swift",
            "ProgramRunScreen.swift", "WorkoutHistoryView.swift", "WorkoutEngine.swift", "WorkoutPlayer.swift", "WorkoutScreens.swift", "Resources", "SportFit.entitlements"
        ], sources: ["InsightsModels.swift", "QuarterReport.swift", "ReminderPlan.swift", "HealthData.swift", "ProgramRun.swift", "DetailedProgram.swift", "HistoryFilter.swift", "Models.swift", "Validation.swift", "LocalFiles.swift", "WorkoutModels.swift", "BodyMeasurement.swift", "UserProfile.swift"]),
        .testTarget(name: "SportFitCoreTests", dependencies: ["SportFitCore"], path: "Tests/Core")
    ]
)
