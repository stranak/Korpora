import Cocoa

/// Installed as `NSDocumentController.shared` (see `main.swift`). The default
/// `NSDocumentController` behavior already suffices for creating a new
/// `ConcordanceDocument` (it's the only declared document type) - the
/// "ask for a corpus + CQL query first" sheet is triggered from
/// `ConcordanceDocument.makeWindowControllers()` instead, since AppKit's
/// automatic untitled-document-at-launch path calls
/// `openUntitledDocumentAndDisplay(false)` and shows the window itself
/// through a separate path, not through this override.
final class KorporaDocumentController: NSDocumentController {
}
