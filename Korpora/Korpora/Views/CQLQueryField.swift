import Cocoa

/// A CQL query editor: an auto-growing, syntax-colored, completion-capable
/// text field. Used both in the "new concordance" sheet and in a document
/// window's persistent query bar.
///
/// Completes CQL's own keywords always, plus - when an owner supplies a
/// `completionProvider` - the corpus's attribute names and attribute
/// values, depending on where the caret is (Phase 6.8; see
/// `CQLCompletionContext`). Without a provider it still completes keywords,
/// so a field with no corpus context behaves exactly as it did before.
final class CQLQueryField: NSView {
    // Not `private` - `CQLCompletionProvider` serves these for the
    // `.keyword` context, so that all three candidate kinds come from one
    // place rather than being split across the two types.
    static let keywords = [
        "within", "containing", "meet", "union", "contains",
    ]

    /// Supplies attribute-name/value candidates for one corpus. Set by
    /// whichever controller owns this field and knows which corpus is
    /// being queried; nil means keyword-only completion.
    var completionProvider: CQLCompletionProvider?

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

        /// Synchronous by AppKit's design, which is the whole difficulty:
        /// attribute *values* live in an on-disk lexicon behind an actor,
        /// so they can't be awaited here. Instead the provider serves
        /// whatever it already has and starts a fetch for what it doesn't;
        /// when that lands, `complete(nil)` re-opens the popup and this
        /// runs again, by which time the value is cached.
        ///
        /// The re-trigger can't loop: the provider caches misses as well as
        /// hits, so the second pass finds an entry either way and starts no
        /// further fetch.
        override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
            guard let provider = (delegate as? CQLQueryField)?.completionProvider else {
                // No corpus context - keywords only, as before 6.8.
                let word = (string as NSString).substring(with: charRange).lowercased()
                guard !word.isEmpty else { return nil }
                let matches = CQLQueryField.keywords.filter { $0.hasPrefix(word) }
                return matches.isEmpty ? nil : matches
            }
            let context = CQLCompletionContext.at(text: string, partialWordRange: charRange)
            return provider.candidates(for: context) { [weak self] in
                // Only reached when a value fetch just finished. Re-ask for
                // completions rather than trying to inject them into the
                // popup that has since been dismissed.
                self?.complete(nil)
            }
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
