import Foundation

/// Tracks whether a corpus import is currently running, so quitting the app
/// can warn before silently discarding what might be hours of compile work
/// (see `AppDelegate.applicationShouldTerminate`) - narrowly scoped to just
/// this one case. Every other document/window in this app closes or quits
/// with no prompt at all, by deliberate design (see docs/project-plan.md's
/// "Document persistence model" note) - this is the one, specific exception,
/// not a crack that should widen into prompting for anything else.
final class ActiveImportTracker {
    static let shared = ActiveImportTracker()
    private(set) var isImporting = false
    private init() {}

    func setImporting(_ value: Bool) {
        isImporting = value
    }
}
