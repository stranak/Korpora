import Cocoa

/// A CQL query editor: an auto-growing, syntax-colored, completion-capable
/// text field. Used both in the "new concordance" sheet and in a document
/// window's persistent query bar.
///
/// Completion covers the CQL *language* and the corpus *schema* - keywords,
/// comparison operators, and both positional and structural attribute
/// names - depending on where the caret is (Phase 6.8; see
/// `CQLCompletionContext`). Brackets and quotes also auto-close, with the
/// caret left between them (`CQLAutoPairing`).
///
/// It deliberately does **not** complete attribute values from the corpus:
/// everything here is small, fixed and knowable up front, which is what
/// keeps it synchronous and predictable.
///
/// Without a `completionProvider` it still completes keywords and
/// operators and still auto-pairs, so a field with no corpus context is
/// fully functional - it just can't offer attribute names.
final class CQLQueryField: NSView {
    /// Supplies language and attribute-name candidates for one corpus. Set
    /// by whichever controller owns this field and knows which corpus is
    /// being queried; nil means no attribute names.
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

        /// Whether the last edit was text going *in*. Completion pops up
        /// only on insertion: firing it on backspace fights the user, who
        /// is deleting precisely because they don't want the suggestion.
        private var lastEditWasInsertion = false
        /// Set while AppKit is inserting a chosen completion. That edit
        /// also lands in `textDidChange`, so without this the popup would
        /// immediately reopen on top of the completion it just accepted.
        private var isInsertingCompletion = false

        override func insertNewline(_ sender: Any?) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                super.insertNewline(sender)
            } else {
                onSubmit?()
            }
        }

        override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
            candidates(forPartialWordRange: charRange)
        }

        /// The single source of candidates, shared by AppKit's completion
        /// callback and the auto-trigger below - so "would a popup show
        /// anything?" and "what does it show?" can never disagree.
        func candidates(forPartialWordRange charRange: NSRange) -> [String]? {
            let context = CQLCompletionContext.at(text: string, partialWordRange: charRange)
            if let provider = (delegate as? CQLQueryField)?.completionProvider {
                return provider.candidates(for: context)
            }
            // No corpus, so no attribute names - but the language half
            // needs nothing from a corpus and still works.
            switch context {
            case .keyword(let prefix):
                return CQLCompletionProvider.matching(CQLCompletionProvider.keywords, prefix: prefix)
            case .comparisonOperator(let prefix):
                return CQLCompletionProvider.matching(
                    CQLCompletionProvider.comparisonOperators, prefix: prefix)
            case .attributeName, .value:
                return nil
            }
        }

        /// Shows the completion popup if the caret is somewhere with
        /// something to offer.
        ///
        /// `NSTextView.complete(_:)` is an action method - AppKit binds it
        /// to Escape/F5 and otherwise never calls it, so before this the
        /// feature was effectively invisible: in the New Concordance and
        /// Filter sheets Escape is the Cancel button's key equivalent, so
        /// it dismissed the sheet instead of completing. Driving it from
        /// the text-did-change hook makes it behave like a code editor,
        /// and Escape still works where it isn't taken.
        ///
        /// Only fires when there are candidates, so it can't flicker an
        /// empty popup, and never on deletion or while accepting a
        /// completion.
        func autoCompleteIfUseful() {
            guard lastEditWasInsertion, !isInsertingCompletion else { return }
            let range = rangeForUserCompletion
            guard range.location != NSNotFound else { return }
            guard let candidates = candidates(forPartialWordRange: range), !candidates.isEmpty else {
                return
            }
            complete(nil)
        }

        override func insertCompletion(
            _ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool
        ) {
            isInsertingCompletion = true
            defer { isInsertingCompletion = false }
            super.insertCompletion(
                word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        }

        /// Auto-closes brackets and quotes, and steps over a closer that's
        /// already there instead of doubling it - see `CQLAutoPairing`.
        ///
        /// Routed through `insertText(_:replacementRange:)` rather than
        /// `keyDown`, so it applies to whatever produces the character
        /// (including a dead-key sequence or the character palette) and so
        /// it composes with `NSTextView`'s own undo grouping.
        override func insertText(_ string: Any, replacementRange: NSRange) {
            lastEditWasInsertion = true
            let input = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
            switch CQLAutoPairing.action(
                forTyping: input, text: self.string, selectedRange: selectedRange()) {
            case .insert(let text, let caretOffset):
                let start = selectedRange().location
                super.insertText(text, replacementRange: replacementRange)
                setSelectedRange(NSRange(location: start + caretOffset, length: 0))
            case .moveOver:
                setSelectedRange(NSRange(location: selectedRange().location + 1, length: 0))
            case .passThrough:
                super.insertText(string, replacementRange: replacementRange)
            }
        }

        /// Backspacing out of a freshly auto-paired `[|]` removes both
        /// halves - otherwise auto-pairing leaves litter behind every time
        /// someone changes their mind.
        override func deleteBackward(_ sender: Any?) {
            lastEditWasInsertion = false
            guard CQLAutoPairing.deletesEmptyPair(text: string, selectedRange: selectedRange()) else {
                super.deleteBackward(sender)
                return
            }
            let caret = selectedRange().location
            replaceCharacters(in: NSRange(location: caret - 1, length: 2), with: "")
            didChangeText()
        }
    }
}

extension CQLQueryField: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        recolor()
        invalidateHeight()
        onChange?()
        // Last, so the popup is positioned against the already-relaid-out
        // text rather than the pre-edit layout.
        textView.autoCompleteIfUseful()
    }
}
