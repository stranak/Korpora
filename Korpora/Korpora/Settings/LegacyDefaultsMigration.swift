import Foundation

/// One-time carry-over of settings from the app's pre-release bundle
/// identifier. `UserDefaults.standard` is keyed by the bundle id, so the
/// switch from `cz.cuni.mff.ufal.mac-corpora.dev` to
/// `cz.cuni.mff.ufal.korpora` (docs/project-plan.md, "Goal - Ship a signed
/// GitHub release", decision 5) would otherwise silently reset fonts,
/// colors, query history, context widths and window frames to defaults.
///
/// Reading another app's domain works because the app is unsandboxed. The
/// legacy plist is left in place (harmless, and lets an old dev build keep
/// working); a marker key makes this run once, so a setting the user later
/// removes in the new domain doesn't get resurrected on the next launch.
enum LegacyDefaultsMigration {
    static let legacyDomain = "cz.cuni.mff.ufal.mac-corpora.dev"
    static let markerKey = "migratedFromLegacyBundleID"

    /// Call first thing at launch, before anything reads `UserDefaults`.
    static func runIfNeeded(defaults: UserDefaults = .standard) {
        migrate(legacy: defaults.persistentDomain(forName: legacyDomain), into: defaults)
    }

    /// Copies each legacy key the destination doesn't already have, then
    /// sets the marker. Split out from `runIfNeeded` so tests can pass an
    /// explicit legacy dictionary instead of a real on-disk domain.
    static func migrate(legacy: [String: Any]?, into defaults: UserDefaults) {
        guard !defaults.bool(forKey: markerKey) else { return }
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: markerKey)
    }
}
