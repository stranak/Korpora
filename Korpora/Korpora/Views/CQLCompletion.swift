import Cocoa
import ManateeKit

/// What the caret is sitting in, and therefore what `CQLQueryField` should
/// offer to complete (Phase 6.8).
///
/// Pure syntax, deliberately: it takes a string and an offset and returns a
/// case, with no `Corpus`, no actor and no I/O, so the position logic - the
/// part that's actually easy to get wrong - is unit-testable without a live
/// window or corpus (see `CQLCompletionContextTests`).
///
/// Scope note: this deliberately does **not** complete attribute *values*
/// from the corpus. Completion here is about the CQL language and the
/// corpus's schema (attribute names), both of which are small, fixed and
/// knowable up front - so everything stays synchronous. Value completion
/// would mean reading a lexicon of up to ~700k entries from disk behind an
/// actor, inside AppKit's synchronous completion callback.
enum CQLCompletionContext: Equatable {
    /// Not inside a token bracket - CQL's own keywords (`within`,
    /// `containing`, …) are all that makes sense.
    case keyword(prefix: String)
    /// Inside `[…]`, positioned where an attribute name goes: e.g. the
    /// `lem` of `[lem`.
    case attributeName(prefix: String)
    /// Inside `[…]`, right after an attribute name, where a comparison
    /// operator goes: the caret in `[word ` or `[doc.author `.
    case comparisonOperator(prefix: String)
    /// Inside a quoted string. Nothing is offered: the contents are corpus
    /// data (or a regex over it), not language, and completing language
    /// keywords in the middle of a `"…"` would be actively wrong.
    case quotedValue

    /// Classifies the caret at `partialWordRange` (exactly what
    /// `NSTextView.completions(forPartialWordRange:…)` is handed) within
    /// `text`.
    ///
    /// Everything is decided by scanning *backwards* from the start of the
    /// partial word rather than by parsing the query as a whole: a query
    /// being typed is usually not valid CQL yet - `[word=` has an unclosed
    /// bracket - so there's nothing to parse forwards, and a real CQL
    /// parser would simply reject it.
    static func at(text: String, partialWordRange: NSRange) -> CQLCompletionContext {
        let ns = text as NSString
        let start = max(0, min(partialWordRange.location, ns.length))
        let length = max(0, min(partialWordRange.length, ns.length - start))
        let prefix = ns.substring(with: NSRange(location: start, length: length))
        let before = ns.substring(to: start)

        if hasUnclosedQuote(in: before) {
            return .quotedValue
        }
        guard isInsideBrackets(before) else {
            return .keyword(prefix: prefix)
        }
        // Inside brackets the position is decided by what the last
        // non-space character is: an identifier character means a name was
        // just finished, so an operator comes next.
        if prefix.isEmpty, endsWithIdentifier(before) {
            return .comparisonOperator(prefix: prefix)
        }
        return .attributeName(prefix: prefix)
    }

    /// True when a `"` in `before` is still open. A `\"` doesn't count -
    /// it's an escaped quote inside a string, not a delimiter.
    private static func hasUnclosedQuote(in before: String) -> Bool {
        let ns = before as NSString
        var open = false
        var index = 0
        while index < ns.length {
            let ch = ns.character(at: index)
            if ch == UInt16(UnicodeScalar("\\").value) {
                // Skip the escaped character, whatever it is. Only
                // meaningful inside a string, but skipping it outside one
                // is harmless and keeps this a single pass.
                index += 2
                continue
            }
            if ch == UInt16(UnicodeScalar("\"").value) {
                open.toggle()
            }
            index += 1
        }
        return open
    }

    /// True when the last unmatched `[` in `before` is still open - i.e.
    /// there's a `[` with no `]` after it.
    private static func isInsideBrackets(_ before: String) -> Bool {
        guard let open = before.lastIndex(of: "[") else { return false }
        guard let close = before.lastIndex(of: "]") else { return true }
        return open > close
    }

    /// True when `before`, ignoring trailing spaces/tabs, ends in an
    /// identifier character - so `[word `, `[doc.author ` and `[word` all
    /// qualify, while `[`, `[word=` and `[word="x" & ` do not.
    private static func endsWithIdentifier(_ before: String) -> Bool {
        let ns = before as NSString
        var index = ns.length - 1
        while index >= 0, " \t".utf16.contains(ns.character(at: index)) {
            index -= 1
        }
        guard index >= 0 else { return false }
        return isIdentifierCharacter(ns.character(at: index))
    }

    private static func isIdentifierCharacter(_ ch: unichar) -> Bool {
        guard let scalar = UnicodeScalar(ch) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "."
    }
}

/// The candidate lists behind `CQLCompletionContext`, for one corpus.
///
/// Fully synchronous by design - see `CQLCompletionContext`'s scope note.
/// The only thing it needs from the corpus is its *schema*, which comes
/// from registry metadata already parsed at open time (`Corpus.info()`),
/// so it's fetched once up front and never touched again.
///
/// `@MainActor` for the mutable `attributeNames` only; the candidate lists
/// and the two pure functions over them are `nonisolated`, both because
/// they touch no state and because a `CQLQueryField` with no provider
/// still needs them from a synchronous AppKit callback.
@MainActor
final class CQLCompletionProvider {
    /// CQL's word-like language constructs. Matches the set
    /// `CQLQueryField.recolor` already highlights as keywords, so what's
    /// completed and what's colored can't drift apart.
    nonisolated static let keywords = [
        "within", "containing", "meet", "union", "contains",
    ]

    /// Comparison operators, matching the set `CQLQueryField.recolor`
    /// highlights. Offered right after an attribute name, where they're the
    /// only thing that can legally come next - and where there's no partial
    /// word to type them into, which is why they're completion candidates
    /// rather than something you'd only ever type by hand.
    nonisolated static let comparisonOperators = ["=", "!=", "<", ">"]

    private(set) var attributeNames: [String] = []

    /// For an owner that has to look the corpus up itself (the query bar,
    /// the Filter sheet).
    init(corpusName: String) {
        prefetchAttributeNames(corpusName: corpusName)
    }

    /// For an owner that already has `info()` in hand - the New Concordance
    /// sheet fetches it anyway to fill its info label, so re-fetching would
    /// be pure waste.
    init(corpusInfo: CorpusInfo) {
        attributeNames = Self.attributeNames(from: corpusInfo)
    }

    /// Both kinds of attribute name, which is what makes this useful for
    /// real queries: positional attributes verbatim (`word`, `lemma`,
    /// `tag`) plus structural ones in the dotted `structure.attribute`
    /// form (`doc.author`, `s.id`) that CQL accepts inside `[…]` - the same
    /// spelling `Corpus.structuralAttributeValue(at:attribute:)` takes.
    ///
    /// Sorted, since the two groups arrive in unrelated registry order and
    /// a completion popup is read by eye.
    nonisolated static func attributeNames(from info: CorpusInfo) -> [String] {
        let structural = info.structures.flatMap { structure in
            structure.attributes.map { "\(structure.name).\($0)" }
        }
        return (info.attributes + structural).sorted()
    }

    /// Candidates for `context`, or nil when there's nothing to offer.
    func candidates(for context: CQLCompletionContext) -> [String]? {
        switch context {
        case .keyword(let prefix):
            return Self.matching(Self.keywords, prefix: prefix)
        case .attributeName(let prefix):
            return Self.matching(attributeNames, prefix: prefix)
        case .comparisonOperator(let prefix):
            return Self.matching(Self.comparisonOperators, prefix: prefix)
        case .quotedValue:
            return nil
        }
    }

    /// Prefix-matched case-insensitively; an empty prefix offers
    /// everything, which is what makes the caret right after `[` (or after
    /// an attribute name) useful rather than dead.
    nonisolated static func matching(_ candidates: [String], prefix: String) -> [String]? {
        guard !prefix.isEmpty else { return candidates.isEmpty ? nil : candidates }
        let lowered = prefix.lowercased()
        let matches = candidates.filter { $0.lowercased().hasPrefix(lowered) }
        return matches.isEmpty ? nil : matches
    }

    private func prefetchAttributeNames(corpusName: String) {
        guard !corpusName.isEmpty else { return }
        Task { @MainActor [weak self] in
            do {
                let corpus = try await Corpus(name: corpusName)
                self?.attributeNames = Self.attributeNames(from: try await corpus.info())
            } catch {
                // Completion is an optional convenience - a corpus that
                // can't be opened or read just means no attribute
                // candidates, never an error in the user's face while
                // they're typing.
                self?.attributeNames = []
            }
        }
    }
}

/// Auto-closing brackets and quotes for `CQLQueryField` (Phase 6.8): type
/// `[` and get `[]` with the caret inside, type the closing character when
/// it's already there and step over it instead of doubling it.
///
/// Pure functions over (text, selection, typed character) so the rules are
/// unit-testable without a text view - the same reason
/// `CQLCompletionContext` is separate from the field.
enum CQLAutoPairing {
    /// Left-right pairs CQL actually uses: token brackets, quoted values,
    /// grouping parens, and structure tags.
    static let pairs: [Character: Character] = ["[": "]", "\"": "\"", "(": ")", "<": ">"]

    /// The closing halves, which is what "step over instead of inserting"
    /// keys off. `"` is deliberately both an opener and a closer - the same
    /// character does both jobs, so which one it is depends entirely on
    /// what's to the right of the caret.
    static var closers: Set<Character> { Set(pairs.values) }

    enum Action: Equatable {
        /// Replace the selection with `text`, then put the caret
        /// `caretOffset` characters into it. Auto-pairing always uses an
        /// offset that lands *between* the two halves.
        case insert(text: String, caretOffset: Int)
        /// The typed character is already the next one - move the caret
        /// past it rather than inserting a duplicate.
        case moveOver
        /// Nothing special; let `NSTextView` insert it normally.
        case passThrough
    }

    static func action(forTyping input: String, text: String, selectedRange: NSRange) -> Action {
        guard input.count == 1, let character = input.first else { return .passThrough }
        let ns = text as NSString
        let caret = max(0, min(selectedRange.location, ns.length))

        // Wrap a selection rather than replacing it: selecting `fox` and
        // typing `"` should give `"fox"`, which is the one case where the
        // caret offset is not 1.
        if selectedRange.length > 0, let close = pairs[character] {
            let selected = ns.substring(with: NSRange(
                location: caret, length: min(selectedRange.length, ns.length - caret)))
            return .insert(text: "\(character)\(selected)\(close)", caretOffset: 1 + selected.count)
        }

        // Step over an existing closer. Checked before the opener case so
        // that `"` closes a string it's sitting at the end of instead of
        // opening a new one.
        if closers.contains(character), caret < ns.length,
           ns.character(at: caret) == character.utf16.first {
            return .moveOver
        }

        if let close = pairs[character] {
            return .insert(text: "\(character)\(close)", caretOffset: 1)
        }
        return .passThrough
    }

    /// Whether backspace should delete both halves of an empty pair - the
    /// caret sitting in `[|]` or `"|"`, which is exactly what's left after
    /// auto-pairing something and changing your mind.
    static func deletesEmptyPair(text: String, selectedRange: NSRange) -> Bool {
        guard selectedRange.length == 0 else { return false }
        let ns = text as NSString
        let caret = selectedRange.location
        guard caret > 0, caret < ns.length else { return false }
        guard let open = Character(utf16: ns.character(at: caret - 1)),
              let close = Character(utf16: ns.character(at: caret)) else { return false }
        return pairs[open] == close
    }
}

extension Character {
    /// Nil for an unpaired surrogate, which can't be a bracket or quote
    /// anyway - so callers can treat nil as "not a pair character".
    fileprivate init?(utf16 unit: unichar) {
        guard let scalar = UnicodeScalar(unit) else { return nil }
        self = Character(scalar)
    }
}
