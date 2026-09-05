import Cocoa

// Must run before any corpus/document lookup - the automatic untitled-
// document-at-launch path fires very early (before applicationDidFinishLaunching).
AppSettings.shared.applyEnvironment()

// The custom NSDocumentController subclass must exist before any document
// opens, or NSDocumentController.shared silently falls back to the default
// class - so it's instantiated here, ahead of NSApplication.main().
_ = CorporaDocumentController()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
