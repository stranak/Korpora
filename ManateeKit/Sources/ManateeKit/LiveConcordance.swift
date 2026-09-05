import CManatee

/// Where a sort key is read from, relative to a concordance hit - matches
/// Manatee's own sort-context convention (`-1<0` = left, `0<0~0>0` = the
/// match itself, `1>0` = right; see conccrit.cc/concctx.cc).
public enum SortAnchor: Sendable, Codable {
    case left, kwic, right
}

/// One level of a (possibly multi-level) sort. `span` is how many tokens of
/// context to read the key from; ignored for `.kwic`, which - mirroring
/// KonText - always sorts on just the match's first token, since a KWIC
/// match's own length varies.
public struct SortLevel: Sendable, Codable {
    public var attribute: String
    public var anchor: SortAnchor
    public var span: Int
    public var caseInsensitive: Bool
    /// Manatee's "retrograde" option (the `r` flag) - compares each word
    /// spelled backwards, e.g. to sort by word ending/suffix rather than by
    /// word start. Not a sort-direction toggle; every sort is ascending.
    public var reverse: Bool

    public init(attribute: String, anchor: SortAnchor, span: Int = 1,
                caseInsensitive: Bool = false, reverse: Bool = false) {
        self.attribute = attribute
        self.anchor = anchor
        self.span = max(span, 1)
        self.caseInsensitive = caseInsensitive
        self.reverse = reverse
    }
}

/// A sort key made of up to 4 levels, matching KonText's own multi-level
/// sort cap (manatee's grammar itself has no such limit, but there's no
/// reason to expose more than KonText's proven UI does).
public struct SortCriteria: Sendable, Codable {
    public var levels: [SortLevel]

    public init(levels: [SortLevel]) {
        precondition(!levels.isEmpty, "SortCriteria needs at least one level")
        self.levels = Array(levels.prefix(4))
    }

    public init(_ level: SortLevel) {
        self.init(levels: [level])
    }

    /// Builds Manatee's own criteria string (conccrit.cc's `prepare_criteria`
    /// grammar) directly - that's already a well-defined format, not
    /// something worth reinventing a parallel representation for.
    var criteriaString: String {
        levels.map { level -> String in
            var flags = ""
            if level.caseInsensitive { flags += "i" }
            if level.reverse { flags += "r" }
            let attrs = flags.isEmpty ? level.attribute : "\(level.attribute)/\(flags)"
            let ctx: String
            switch level.anchor {
            case .kwic: ctx = "0<0~0>0"
            case .left: ctx = "-1<0~-\(level.span)<0"
            case .right: ctx = "1>0~\(level.span)>0"
            }
            return "\(attrs) \(ctx)"
        }.joined(separator: " ")
    }
}

/// Which match, within a filter's context window, to test - see
/// `Concordance::set_collocation`'s `rank` parameter (concord.cc): counted
/// from the left if positive, from the right if negative.
public enum MatchRank: Sendable, Codable {
    case first, last

    var rank: Int32 {
        switch self {
        case .first: return 1
        case .last: return -1
        }
    }
}

/// A positive/negative sub-filter: keep or drop concordance lines depending
/// on whether `query` matches somewhere in [leftOffset, rightOffset] tokens
/// around each hit. Mirrors KonText's filter form exactly (including its
/// -5/5 default window) rather than a redesigned model.
public struct PNFilterSpec: Sendable, Codable {
    public var positive: Bool
    public var leftOffset: Int
    public var rightOffset: Int
    public var rank: MatchRank
    public var includeKwic: Bool
    public var query: String

    public init(positive: Bool, leftOffset: Int = -5, rightOffset: Int = 5,
                rank: MatchRank = .first, includeKwic: Bool = true, query: String) {
        self.positive = positive
        self.leftOffset = leftOffset
        self.rightOffset = rightOffset
        self.rank = rank
        self.includeKwic = includeKwic
        self.query = query
    }
}

/// A single Manatee corpus query, kept open and mutable so sort/shuffle/
/// sample/filter/line-group operations can compose on one running result
/// set - the gap the old open-query-then-discard `Corpus.query` API left.
/// An actor for the same reason `Corpus` is one: Manatee's thread-safety
/// under concurrent access to one handle is undocumented.
public actor LiveConcordance {
    // Keeps the parent corpus alive for as long as this concordance exists -
    // `corpusHandle` is only a raw pointer, so without this a caller that
    // drops its last reference to `Corpus` would have it deinit (closing
    // the underlying handle via `mtc_corpus_close`) out from under a still-
    // live concordance, a use-after-free `mtc_kwic_open` would only sometimes
    // visibly misbehave on.
    private let corpus: Corpus
    private let corpusHandle: OpaquePointer
    private let handle: OpaquePointer

    /// Collocation slot 1 is reserved for filter operations - Manatee numbers
    /// these per-concordance, not per-filter-call, but this wrapper only
    /// ever needs one active at a time (`filter` fully replaces slot 1 each
    /// call rather than layering).
    private static let filterCollocationSlot: Int32 = 1

    public init(corpus: Corpus, cql: String) async throws {
        self.corpus = corpus
        let corpusHandle = await corpus.handle
        self.corpusHandle = corpusHandle
        var error: UnsafeMutablePointer<CChar>?
        guard let h = mtc_query(corpusHandle, cql, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        handle = h
    }

    deinit {
        mtc_concordance_close(handle)
    }

    public var size: Int {
        Int(mtc_concordance_size(handle))
    }

    public func sort(_ criteria: SortCriteria, unique: Bool = false) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard mtc_concordance_sort(handle, criteria.criteriaString, unique ? 1 : 0, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    public func shuffle() throws {
        var error: UnsafeMutablePointer<CChar>?
        guard mtc_concordance_shuffle(handle, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    /// Reduces to (approximately) `lines` lines. Resets any prior sort/
    /// shuffle order - see `mtc_concordance_reduce`'s doc comment; that's
    /// Manatee's own behavior, not a limitation of this wrapper.
    public func sample(lines: Int) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard mtc_concordance_reduce(handle, Int64(lines), &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    public func filter(_ spec: PNFilterSpec) throws {
        var error: UnsafeMutablePointer<CChar>?
        let collnum = Self.filterCollocationSlot
        guard mtc_concordance_set_collocation(
            handle, collnum, spec.query, String(spec.leftOffset), String(spec.rightOffset),
            spec.rank.rank, spec.includeKwic ? 0 : 1, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
        guard mtc_concordance_pnfilter(handle, collnum, spec.positive ? 1 : 0, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    public func setLineGroup(rangeStart: Int, rangeLen: Int, group: Int) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard mtc_concordance_set_linegroup(
            handle, Int64(rangeStart), Int64(rangeLen), Int32(group), &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    public func linegroup(at lineIndex: Int) -> Int {
        Int(mtc_concordance_get_linegroup(handle, Int64(lineIndex)))
    }

    /// Keeps only lines in the given groups, discarding the rest - used to
    /// implement "clear line groups" isn't this; the document layer clears
    /// grouping by dropping line-group operations from its chain and
    /// replaying, since Manatee has no "reset all labels but keep every
    /// line" call of its own (`delete_linegroups` only ever removes lines).
    public func deleteLineGroups(_ groups: [Int], invert: Bool) throws {
        var error: UnsafeMutablePointer<CChar>?
        let spec = groups.map(String.init).joined(separator: " ")
        guard mtc_concordance_delete_linegroups(handle, spec, invert ? 1 : 0, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    public func kwicLines(leftContext: String = "-10", rightContext: String = "10",
                           kwicAttr: String = "word") throws -> [KWICLine] {
        var error: UnsafeMutablePointer<CChar>?
        guard let kwic = mtc_kwic_open(corpusHandle, handle, leftContext, rightContext, kwicAttr, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_kwic_close(kwic) }

        var lines: [KWICLine] = []
        while mtc_kwic_next(kwic) != 0 {
            let left = mtc_kwic_get_left(kwic)
            let center = mtc_kwic_get_kwic(kwic)
            let right = mtc_kwic_get_right(kwic)
            lines.append(KWICLine(
                left: String(cString: left!),
                kwic: String(cString: center!),
                right: String(cString: right!)
            ))
            mtc_free_string(left)
            mtc_free_string(center)
            mtc_free_string(right)
        }
        return lines
    }
}
