import Foundation

struct BodyMeasurement: Codable, Identifiable {
    let id: UUID
    var measuredAt: Date
    var weightKg: Double
    var waistCm: Double?
    var bodyFatPercent: Double?
    var source: String
    var heightCm: Double?
    var chestCm: Double?
    var hipsCm: Double?
    var muscleMassKg: Double?
    var bmi: Double? {
        guard let heightCm, heightCm > 0 else { return nil }
        return weightKg / pow(heightCm / 100, 2)
    }

    init(date: Date, weightKg: Double, waistCm: Double?, bodyFatPercent: Double?) {
        self.id = UUID()
        self.measuredAt = date
        self.weightKg = weightKg
        self.waistCm = waistCm
        self.bodyFatPercent = bodyFatPercent
        self.source = "manual"
    }
}

