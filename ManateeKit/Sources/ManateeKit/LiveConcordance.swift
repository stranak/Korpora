import CManatee

/// Where a sort key is read from, relative to a concordance hit - matches
/// Manatee's own sort-context convention (`-1<0` = left, `0<0~0>0` = the
/// match itself, `1>0` = right; see conccrit.cc/concctx.cc).
public enum SortAnchor: Sendable, Codable, Equatable {
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

/// Manatee's collocation association measures (`corp/bgrstat.hh`'s `bgr_*`
/// functions, selected by a single-char code). This is a curated subset -
/// the ones with real KonText UI usage - not the full code alphabet
/// (`bgr_known_fun_codes` in the engine also has 'p'/'r'/'f'/'F'/'C'/'1',
/// more obscure/less commonly surfaced measures); the shim accepts any
/// valid code, so this can grow later without a shim change.
public enum AssociationMeasure: Character, Sendable, Codable, CaseIterable {
    /// `14 + log2(2*f_AB/(f_A+f_B))` - Manatee/KonText's own conventional
    /// default collocation measure.
    case logDice = "d"
    /// Pointwise mutual information: `log2(f_AB*N/(f_A*f_B))`.
    case mutualInformation = "m"
    /// MI³: like MI but weighted toward higher-frequency collocates.
    case mi3 = "3"
    /// T-score: `(f_AB - f_A*f_B/N) / sqrt(f_AB)`.
    case tScore = "t"
    /// Log-likelihood (Dunning).
    case logLikelihood = "l"
    /// Dice coefficient, 0-100 scale.
    case dice = "D"
}

/// Parameters for `LiveConcordance.collocations(_:)` - mirrors KonText's own
/// collocation form (`cattr`/`csortfn`/`cfromw`/`ctow`), plus the two
/// frequency thresholds Manatee's `CollocItems` itself requires.
public struct CollocationSpec: Sendable, Codable {
    /// Positional attribute the collocate candidates are drawn from and
    /// reported in (e.g. "word", "lemma") - not necessarily the attribute
    /// the query itself matched on.
    public var attribute: String
    public var measure: AssociationMeasure
    /// Context window in tokens relative to each hit - negative scans left,
    /// positive scans right (e.g. -5/5 for 5 tokens on each side).
    public var leftWindow: Int
    public var rightWindow: Int
    /// Minimum corpus-wide frequency a candidate word needs to be
    /// considered at all.
    public var minFrequency: Int
    /// Minimum number of concordance lines a candidate must co-occur in to
    /// be kept ("min. collocation frequency" in KonText UI terms).
    public var minCollocateFrequency: Int
    /// Hard cap on how many top-scoring collocates are returned.
    public var maxItems: Int

    public init(attribute: String, measure: AssociationMeasure = .logDice,
                leftWindow: Int = -5, rightWindow: Int = 5,
                minFrequency: Int = 5, minCollocateFrequency: Int = 3, maxItems: Int = 50) {
        self.attribute = attribute
        self.measure = measure
        self.leftWindow = leftWindow
        self.rightWindow = rightWindow
        self.minFrequency = minFrequency
        self.minCollocateFrequency = minCollocateFrequency
        self.maxItems = maxItems
    }
}

/// One collocate returned by `LiveConcordance.collocations(_:)`, best-scoring
/// first.
public struct CollocationItem: Sendable, Equatable {
    public let word: String
    /// Corpus-wide frequency of the collocate word (independent of `score`).
    public let freq: Int
    /// Number of concordance lines this word co-occurred in with the node.
    public let cnt: Int
    /// The requested `CollocationSpec.measure`'s value for this row.
    public let score: Double
}

/// One grouping key for `LiveConcordance.frequencyDistribution(_:minFrequency:)`.
/// Manatee's own criteria-string grammar (see `SortCriteria.criteriaString`)
/// supports joining several of these into one multi-level key, though the
/// first UI surface built on this only ever passes one.
public struct FrequencyCriterion: Sendable, Codable {
    /// A positional attribute (e.g. "lemma") or a structural one written
    /// "struct.attr" (e.g. "doc.author") - the latter is what makes `norm`
    /// meaningful on the resulting `FrequencyItem`s.
    public var attribute: String
    /// Token offset relative to each hit (0 = the hit itself).
    public var contextOffset: Int
    public var caseInsensitive: Bool

    public init(attribute: String, contextOffset: Int = 0, caseInsensitive: Bool = false) {
        self.attribute = attribute
        self.contextOffset = contextOffset
        self.caseInsensitive = caseInsensitive
    }

    var criteriaFragment: String {
        let attrs = caseInsensitive ? "\(attribute)/i" : attribute
        return "\(attrs) \(contextOffset)"
    }
}

/// One bin from `LiveConcordance.frequencyDistribution(_:minFrequency:)`,
/// sorted by `freq` descending.
public struct FrequencyItem: Sendable {
    /// The (possibly multi-level, tab-joined) key this bin was grouped by.
    public let word: String
    public let freq: Int
    /// A per-struct-value token count, only present when the first
    /// criterion is a structural attribute - usable to compute a relative/
    /// normalized frequency. `nil` for a plain positional-attribute criterion.
    public let norm: Int?
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
        let corpusHandle = corpus.handle
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

    /// `secondaryAttributes` (e.g. `["lemma", "tag"]`) are read alongside
    /// `kwicAttr` per token, for a caller wanting to show more than one
    /// attribute per word (KonText-style) - see `KWICToken`. Fetching N
    /// secondary attributes costs 3N extra bridge calls per line (one per
    /// left/kwic/right segment per attribute) on top of the 3 already made
    /// for `kwicAttr` itself - fine for the handful of attributes a picker
    /// UI realistically requests, but something to keep in mind against an
    /// already-large, unpaginated result set (`kwicLines` fetches every
    /// hit's line up front, regardless of how many are ever shown).
    public func kwicLines(leftContext: String = "-10", rightContext: String = "10",
                           kwicAttr: String = "word", secondaryAttributes: [String] = []) throws -> [KWICLine] {
        var error: UnsafeMutablePointer<CChar>?
        guard let kwic = mtc_kwic_open(corpusHandle, handle, leftContext, rightContext, kwicAttr, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_kwic_close(kwic) }

        // Nested functions (not `Self.`-scoped helpers) so both capture
        // `error` by reference - `decode` must see whatever `error` a
        // `fetch` call just set, at the moment it actually failed, not a
        // value snapshotted before that call ran.
        func decode(_ cString: UnsafeMutablePointer<CChar>?) throws -> [String] {
            guard let cString else {
                throw ManateeError.failure(consumeError(error))
            }
            defer { mtc_free_string(cString) }
            let joined = String(cString: cString)
            guard !joined.isEmpty else { return [] }
            // Leading-delimiter encoding - see mtcbridge.h's doc comment on
            // mtc_kwic_get_left_attr for why this isn't a plain split.
            return joined.dropFirst().components(separatedBy: "\u{1F}")
        }

        func segment(_ fetch: (String) -> UnsafeMutablePointer<CChar>?) throws -> [KWICToken] {
            let words = try decode(fetch(kwicAttr))
            var secondary = Array(repeating: [String: String](), count: words.count)
            for attribute in secondaryAttributes {
                let values = try decode(fetch(attribute))
                for (index, value) in values.enumerated() where secondary.indices.contains(index) {
                    secondary[index][attribute] = value
                }
            }
            return zip(words, secondary).map(KWICToken.init)
        }

        var lines: [KWICLine] = []
        while mtc_kwic_next(kwic) != 0 {
            lines.append(KWICLine(
                leftTokens: try segment { mtc_kwic_get_left_attr(kwic, $0, &error) },
                kwicTokens: try segment { mtc_kwic_get_kwic_attr(kwic, $0, &error) },
                rightTokens: try segment { mtc_kwic_get_right_attr(kwic, $0, &error) },
                position: Int(mtc_kwic_get_pos(kwic))
            ))
        }
        return lines
    }

    /// Top collocates of the concordance's current hits, best-scoring first.
    public func collocations(_ spec: CollocationSpec) throws -> [CollocationItem] {
        var error: UnsafeMutablePointer<CChar>?
        let measureCode = CChar(spec.measure.rawValue.asciiValue!)
        guard let items = mtc_colloc_open(
            handle, spec.attribute, measureCode,
            Int64(spec.minFrequency), Int64(spec.minCollocateFrequency),
            Int32(spec.leftWindow), Int32(spec.rightWindow), Int32(spec.maxItems), &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_colloc_close(items) }

        var results: [CollocationItem] = []
        while mtc_colloc_next(items) != 0 {
            let word = mtc_colloc_get_item(items)
            let freq = mtc_colloc_get_freq(items)
            let cnt = mtc_colloc_get_cnt(items)
            let score = mtc_colloc_get_bgr(items, measureCode)
            results.append(CollocationItem(word: String(cString: word!), freq: Int(freq), cnt: Int(cnt), score: score))
            mtc_free_string(word)
        }
        return results
    }

    /// Frequency distribution of the concordance's current hits, grouped by
    /// `criteria` (joined into one multi-level Manatee criteria string) and
    /// sorted by frequency descending. Only bins with at least `minFrequency`
    /// hits are included.
    public func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int = 1) throws -> [FrequencyItem] {
        precondition(!criteria.isEmpty, "frequencyDistribution needs at least one criterion")
        let crit = criteria.map(\.criteriaFragment).joined(separator: " ")
        // Only the *first* criterion determines whether `norm` is meaningful
        // (see Corpus::freq_dist - it looks at the first criterion's attribute).
        let normIsMeaningful = criteria[0].attribute.contains(".")

        var error: UnsafeMutablePointer<CChar>?
        guard let dist = mtc_freq_dist_open(handle, crit, Int64(minFrequency), &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_freq_dist_close(dist) }

        var results: [FrequencyItem] = []
        let count = Int(mtc_freq_dist_count(dist))
        results.reserveCapacity(count)
        for i in 0..<count {
            let word = mtc_freq_dist_get_word(dist, Int32(i))
            let freq = mtc_freq_dist_get_freq(dist, Int32(i))
            let norm = mtc_freq_dist_get_norm(dist, Int32(i))
            results.append(FrequencyItem(
                word: String(cString: word!), freq: Int(freq),
                norm: normIsMeaningful ? Int(norm) : nil))
            mtc_free_string(word)
        }
        return results
    }
}
