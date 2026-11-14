import XCTest
@testable import SportFit

private final class LegacyFixtureAnchor: NSObject {}
@MainActor enum LegacyFixture {
    static var assets: URL { Bundle(for: LegacyFixtureAnchor.self).url(forResource: "LegacyData", withExtension: nil)! }
    static func store(directory: URL) -> FitnessStore { FitnessStore(directory: directory, bundledDirectory: assets) }
}
