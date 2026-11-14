import Foundation

struct UserProfile: Codable {
    var name = ""
    var heightCm: Double?
    var targetWeightKg: Double?
    var goal = ""
    var notificationsEnabled = false
}

struct ScheduleChange: Codable, Identifiable {
    var id: String { programId + ":" + originalDate }
    let programId: String
    let originalDate: String
    var movedTo: String?
    var skipped: Bool
}

