import Cocoa

/// A CQL query editor: an auto-growing, syntax-colored, completion-capable
/// text field. Used both in the "new concordance" sheet and in a document
/// window's persistent query bar.
///
/// Attribute-name/tag-value completion needs corpus registry introspection,
/// which isn't in the shim yet (planned for Phase 2) - for now this only
/// completes CQL's own keywords/operators.
final class CQLQueryField: NSView {
    private static let keywords = [
        "within", "containing", "meet", "union", "contains",
    ]

    private static let minHeight: CGFloat = 22
    private static let maxHeight: CGFloat = 160

    private let scrollView = NSScrollView()
    // Not `private` - callers need it to wire this view into a key-view
    // loop (`nextKeyView`) and to call `focus()`'s `makeFirstResponder`.
    // `CQLQueryField` itself never accepts first responder (NSView's
    // default, unchanged) - only this nested text view actually edits.
    let textView: InternalTextView

    var text: String {
        get { textView.string }
        set { textView.string = newValue; recolor(); invalidateHeight() }
    }

    /// Called when the user presses Enter (without Shift) to run the query.
    var onSubmit: (() -> Void)?
    /// Called after every edit, so an owner can e.g. enable/disable a Search button.
    var onChange: (() -> Void)?

    private var heightConstraint: NSLayoutConstraint!

    /// Focuses the actual editable text view - nothing does this
    /// automatically just because this view is on screen (a custom
    /// composite view like this one isn't a standard control, so neither
    /// AppKit's initial-first-responder heuristics nor its auto-generated
    /// Tab key-view loop reliably reach into it on their own; see
    /// `NewConcordanceSheetController.viewDidAppear`/`loadView`, which call
    /// this and wire `nextKeyView` explicitly rather than relying on that).
    @discardableResult
    func focus() -> Bool {
        window?.makeFirstResponder(textView) ?? false
    }

    override init(frame frameRect: NSRect) {
        textView = InternalTextView()
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        textView = InternalTextView()
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        textView.delegate = self
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 3)
        textView.onSubmit = { [weak self] in self?.onSubmit?() }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.drawsBackground = true

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.minHeight)
        heightConstraint.isActive = true
    }

    private func invalidateHeight() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let target = min(max(used.height + textView.textContainerInset.height * 2, Self.minHeight), Self.maxHeight)
        heightConstraint.constant = target
    }

    private func recolor() {
        let text = textView.string as NSString
        let storage = textView.textStorage!
        let full = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        Self.color(pattern: #"\"(?:[^\"\\]|\\.)*\""#, in: text, storage: storage, color: .systemRed)
        Self.color(pattern: #"\b(within|containing|meet|union|contains)\b"#, in: text, storage: storage, color: .systemPurple)
        Self.color(pattern: #"(!=|=|<|>|!)"#, in: text, storage: storage, color: .systemOrange)
        Self.color(pattern: #"</?[a-zA-Z][\w]*[^>]*>"#, in: text, storage: storage, color: .systemTeal)
        storage.endEditing()
    }

    /// The same CQL syntax coloring `recolor()` applies live, factored out
    /// so a non-editable rendering (e.g. `ConcordanceViewController
    /// .printConcordance`'s printed/PDF'd page header) can match it exactly
    /// without needing a real `NSTextView` to hang it off of.
    static func syntaxColoredAttributedString(for query: String, font: NSFont) -> NSAttributedString {
        let text = query as NSString
        let storage = NSTextStorage(
            string: query, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        Self.color(pattern: #"\"(?:[^\"\\]|\\.)*\""#, in: text, storage: storage, color: .systemRed)
        Self.color(pattern: #"\b(within|containing|meet|union|contains)\b"#, in: text, storage: storage, color: .systemPurple)
        Self.color(pattern: #"(!=|=|<|>|!)"#, in: text, storage: storage, color: .systemOrange)
        Self.color(pattern: #"</?[a-zA-Z][\w]*[^>]*>"#, in: text, storage: storage, color: .systemTeal)
        return storage
    }

    private static func color(pattern: String, in text: NSString, storage: NSTextStorage, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        regex.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let range = match?.range else { return }
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    /// Text view subclass so Enter/Shift-Enter and completion can be intercepted
    /// without a separate delegate round-trip for every keystroke.
    /// Not `private` - `textView`'s own declared type must be at least as
    /// visible as that (now internal) property itself.
    final class InternalTextView: NSTextView {
        var onSubmit: (() -> Void)?

        override func insertNewline(_ sender: Any?) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                super.insertNewline(sender)
            } else {
                onSubmit?()
            }
        }

        override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
            let word = (string as NSString).substring(with: charRange).lowercased()
            guard !word.isEmpty else { return nil }
            let matches = CQLQueryField.keywords.filter { $0.hasPrefix(word) }
            return matches.isEmpty ? nil : matches
        }
    }
}

extension CQLQueryField: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        recolor()
        invalidateHeight()
        onChange?()
    }
}
