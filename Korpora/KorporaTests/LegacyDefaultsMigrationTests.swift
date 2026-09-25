import Foundation
import Testing
@testable import Korpora

@Suite struct LegacyDefaultsMigrationTests {
    /// A private, isolated suite per test - never touches the user's real
    /// `UserDefaults.standard`.
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LegacyDefaultsMigrationTests-\(UUID().uuidString)")!
    }

    @Test func copiesLegacyKeysAndSetsMarker() {
        let defaults = freshDefaults()
        LegacyDefaultsMigration.migrate(legacy: ["leftContextWidth": 42, "fontName": "Menlo"], into: defaults)
        #expect(defaults.integer(forKey: "leftContextWidth") == 42)
        #expect(defaults.string(forKey: "fontName") == "Menlo")
        #expect(defaults.bool(forKey: LegacyDefaultsMigration.markerKey))
    }

    @Test func neverOverwritesAValueAlreadyInTheNewDomain() {
        let defaults = freshDefaults()
        defaults.set("Monaco", forKey: "fontName")
        LegacyDefaultsMigration.migrate(legacy: ["fontName": "Menlo"], into: defaults)
        #expect(defaults.string(forKey: "fontName") == "Monaco")
    }

    @Test func runsOnlyOnce() {
        let defaults = freshDefaults()
        LegacyDefaultsMigration.migrate(legacy: ["fontName": "Menlo"], into: defaults)
        defaults.removeObject(forKey: "fontName")   // user reset it afterwards
        LegacyDefaultsMigration.migrate(legacy: ["fontName": "Menlo"], into: defaults)
        #expect(defaults.object(forKey: "fontName") == nil)
    }

    @Test func noLegacyDomainStillSetsMarker() {
        let defaults = freshDefaults()
        LegacyDefaultsMigration.migrate(legacy: nil, into: defaults)
        #expect(defaults.bool(forKey: LegacyDefaultsMigration.markerKey))
    }
}
