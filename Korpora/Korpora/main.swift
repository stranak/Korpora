import Cocoa

// Before anything reads UserDefaults: carry settings over from the
// pre-release bundle id (see LegacyDefaultsMigration).
LegacyDefaultsMigration.runIfNeeded()

// Must run before any corpus/document lookup - the automatic untitled-
// document-at-launch path fires very early (before applicationDidFinishLaunching).
AppSettings.shared.applyEnvironment()

// Carry the old registry-directories setting and per-corpus "Keep in Memory"
// flags into the unified corpus list (once).
AppSettings.shared.migrateCorpusList()

// The custom NSDocumentController subclass must exist before any document
// opens, or NSDocumentController.shared silently falls back to the default
// class - so it's instantiated here, ahead of NSApplication.main().
_ = KorporaDocumentController()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
