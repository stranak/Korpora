import Cocoa
import ManateeKit

/// What the caret is sitting in, and therefore what `CQLQueryField` should
/// offer to complete (Phase 6.8).
///
/// Pure syntax, deliberately: it takes a string and an offset and returns a
/// case, with no `Corpus`, no actor and no I/O, so the position logic - the
/// part that's actually easy to get wrong - is unit-testable without a live
/// window or corpus (see `CQLCompletionContextTests`). Turning a case into
/// actual candidates is `CQLCompletionProvider`'s job.
enum CQLCompletionContext: Equatable {
    /// Not inside a token bracket - CQL's own keywords (`within`,
    /// `containing`, …) are all that makes sense.
    case keyword(prefix: String)
    /// Inside `[…]` but not inside a quoted value: an attribute name, e.g.
    /// the `lem` of `[lem`.
    case attributeName(prefix: String)
    /// Inside a quoted value belonging to `attribute`, e.g. the `fo` of
    /// `[word="fo`. `attribute` is whatever name preceded the `=`, verbatim
    /// and unvalidated - the provider decides whether the corpus has it.
    case attributeValue(attribute: String, prefix: String)

    /// Classifies the caret at `partialWordRange` (exactly what
    /// `NSTextView.completions(forPartialWordRange:…)` is handed) within
    /// `text`.
    ///
    /// Everything is decided by scanning *backwards* from the start of the
    /// partial word rather than by parsing the query as a whole: a query
    /// being typed is usually not valid CQL yet - `[word="fo` has an
    /// unclosed quote and an unclosed bracket - so there's nothing to parse
    /// forwards, and a real CQL parser would simply reject it.
    static func at(text: String, partialWordRange: NSRange) -> CQLCompletionContext {
        let ns = text as NSString
        let start = max(0, min(partialWordRange.location, ns.length))
        let length = max(0, min(partialWordRange.length, ns.length - start))
        let prefix = ns.substring(with: NSRange(location: start, length: length))
        let before = ns.substring(to: start)

        // A value is recognized by an unclosed quote, which also covers the
        // unbracketed `author="Tw` form the "New Subcorpus…" popover uses
        // (see `Corpus.createSubcorpus` on why that one has no brackets).
        if let quoteStart = unclosedQuoteStart(in: before) {
            let attribute = attributeName(endingBefore: quoteStart, in: before)
            return .attributeValue(attribute: attribute, prefix: prefix)
        }
        if isInsideBrackets(before) {
            return .attributeName(prefix: prefix)
        }
        return .keyword(prefix: prefix)
    }

    /// The offset of the `"` that opens a still-unclosed string, or nil if
    /// every quote in `before` is balanced. A `\"` doesn't count - it's an
    /// escaped quote inside a string, not a delimiter.
    private static func unclosedQuoteStart(in before: String) -> Int? {
        let ns = before as NSString
        var openedAt: Int?
        var index = 0
        while index < ns.length {
            let ch = ns.character(at: index)
            if ch == UInt16(UnicodeScalar("\\").value) {
                // Skip the escaped character, whatever it is. Only
                // meaningful while inside a string, but skipping it outside
                // one too is harmless and keeps this a single pass.
                index += 2
                continue
            }
            if ch == UInt16(UnicodeScalar("\"").value) {
                openedAt = openedAt == nil ? index : nil
            }
            index += 1
        }
        return openedAt
    }

    /// True when the last unmatched `[` in `before` is still open - i.e.
    /// there's a `[` with no `]` after it.
    private static func isInsideBrackets(_ before: String) -> Bool {
        guard let open = before.lastIndex(of: "[") else { return false }
        guard let close = before.lastIndex(of: "]") else { return true }
        return open > close
    }

    /// Reads the attribute name immediately left of the opening quote at
    /// `quoteStart`, skipping the comparison operator and any whitespace
    /// between them - so `word="`, `word = "`, `word!="` and `word !== "`
    /// all yield "word". Empty string when there's no identifier there
    /// (e.g. a bare `"…"` string), which the provider treats as "no
    /// attribute, nothing to offer".
    private static func attributeName(endingBefore quoteStart: Int, in before: String) -> String {
        let ns = before as NSString
        var index = quoteStart - 1
        // The operator and its surrounding spaces: = == != and stray ! < >.
        while index >= 0, "=!<> \t".utf16.contains(ns.character(at: index)) {
            index -= 1
        }
        let nameEnd = index
        while index >= 0, isIdentifierCharacter(ns.character(at: index)) {
            index -= 1
        }
        guard nameEnd > index else { return "" }
        return ns.substring(with: NSRange(location: index + 1, length: nameEnd - index))
    }

    private static func isIdentifierCharacter(_ ch: unichar) -> Bool {
        guard let scalar = UnicodeScalar(ch) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "."
    }
}

/// Turns a `CQLCompletionContext` into candidate strings for one corpus.
///
/// Exists because `NSTextView.completions(forPartialWordRange:…)` is
/// **synchronous** while `Corpus` is an actor and its lexicon lives on
/// disk - there is no way to await inside that callback. So attribute
/// names are prefetched once (they come from already-parsed registry
/// metadata and are tiny), and attribute *values* are served from a cache
/// that a background fetch fills, re-triggering the completion popup when
/// it lands (see `CQLQueryField.InternalTextView.completions`).
@MainActor
final class CQLCompletionProvider {
    /// A completion popup is a list to glance at, not a data browser -
    /// `lemma` has 708,671 distinct values on syn2025 (see Phase 6.7), so
    /// the limit is what keeps this usable rather than a nicety.
    private static let maxValueCandidates = 50

    private let corpusName: String
    private var corpus: Corpus?
    private var attributeNames: [String] = []
    /// Keyed by attribute *and* prefix, and it deliberately caches misses
    /// too: an empty array recorded for a prefix is what stops
    /// `completions` from re-fetching (and so re-triggering itself) for a
    /// prefix already known to match nothing.
    private var valueCache: [String: [String]] = [:]
    private var inFlight: Set<String> = []

    init(corpusName: String, attributeNames: [String] = []) {
        self.corpusName = corpusName
        self.attributeNames = attributeNames
        if attributeNames.isEmpty {
            prefetchAttributeNames()
        }
    }

    /// Candidates for `context`, or nil when there's nothing to offer yet.
    ///
    /// `onValuesFetched` is called only when values had to be fetched: the
    /// return value is nil in that case, and the caller should re-ask once
    /// the callback fires.
    func candidates(for context: CQLCompletionContext, onValuesFetched: @escaping () -> Void) -> [String]? {
        switch context {
        case .keyword(let prefix):
            return Self.matching(CQLQueryField.keywords, prefix: prefix)
        case .attributeName(let prefix):
            return Self.matching(attributeNames, prefix: prefix)
        case .attributeValue(let attribute, let prefix):
            guard !attribute.isEmpty, attributeNames.contains(attribute) else { return nil }
            let key = Self.cacheKey(attribute, prefix)
            if let cached = valueCache[key] {
                return cached.isEmpty ? nil : cached
            }
            fetchValues(attribute: attribute, prefix: prefix, key: key, then: onValuesFetched)
            return nil
        }
    }

    private static func matching(_ candidates: [String], prefix: String) -> [String]? {
        guard !prefix.isEmpty else { return candidates.isEmpty ? nil : candidates }
        let lowered = prefix.lowercased()
        let matches = candidates.filter { $0.lowercased().hasPrefix(lowered) }
        return matches.isEmpty ? nil : matches
    }

    private static func cacheKey(_ attribute: String, _ prefix: String) -> String {
        // \u{0} can't occur in either part, so this can't collide the way
        // a "." or ":" separator could against a dotted attribute name.
        "\(attribute)\u{0}\(prefix)"
    }

    private func prefetchAttributeNames() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let corpus = try await self.openCorpus()
                self.attributeNames = try await corpus.info().attributes
            } catch {
                // Completion is an optional convenience - a corpus that
                // can't be opened or read just means no candidates, never
                // an error in the user's face while they're typing.
                self.attributeNames = []
            }
        }
    }

    private func fetchValues(attribute: String, prefix: String, key: String, then completion: @escaping () -> Void) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(key) }
            do {
                let corpus = try await self.openCorpus()
                // Whole-value matching, so a prefix search needs the
                // trailing ".*" - see `Corpus.attributeValues`. The typed
                // text is escaped first: someone typing "a." in a lemma
                // box means a literal dot, not "any character".
                let pattern = Self.escapeForRegex(prefix) + ".*"
                self.valueCache[key] = try await corpus.attributeValues(
                    attribute: attribute, matching: pattern, ignoreCase: true,
                    limit: Self.maxValueCandidates)
            } catch {
                // Cache the failure as a miss, so a broken attribute or
                // corpus doesn't re-fetch on every keystroke.
                self.valueCache[key] = []
            }
            completion()
        }
    }

    private func openCorpus() async throws -> Corpus {
        if let corpus { return corpus }
        let opened = try await Corpus(name: corpusName)
        corpus = opened
        return opened
    }

    /// Escapes Manatee's regex metacharacters so the typed prefix is
    /// matched literally - someone typing "a." in a lemma box means a
    /// literal dot, not "any character".
    ///
    /// `nonisolated` because it touches no state: it's pure string work
    /// that happens to live here, and inheriting the type's `@MainActor`
    /// would only make it unusable from a synchronous test.
    nonisolated static func escapeForRegex(_ text: String) -> String {
        var result = ""
        for character in text {
            if #"\.*+?[](){}|^$"#.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
