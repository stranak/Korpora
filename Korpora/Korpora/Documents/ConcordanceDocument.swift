import Cocoa
import ManateeKit

struct ConcordanceRow {
    let id: Int
    let line: KWICLine
    let group: Int
    /// The value of `ConcordanceDocument.structuralAttributeToShow` for
    /// this line's enclosing structure - nil if that setting is itself
    /// nil, or if this line's structure has no value for it.
    let structuralAttributeValue: String?

    init(id: Int, line: KWICLine, group: Int, structuralAttributeValue: String? = nil) {
        self.id = id
        self.line = line
        self.group = group
        self.structuralAttributeValue = structuralAttributeValue
    }
}

/// KWIC (a fixed number of tokens each side, `leftContext`/`rightContext`)
/// vs. Sentence (context expands to the enclosing `<s>` boundary,
/// regardless of `leftContext`/`rightContext`'s numeric value - see
/// `ConcordanceDocument.effectiveLeftContext`/`.effectiveRightContext`).
/// KonText keeps this as a switch independent of the numeric context
/// width control, rather than folding it into that same control.
enum ConcordanceViewMode: String, Codable {
    case kwic
    case sentence
}

/// How "Extended Context…" (Phase 6.6) presents a hit's wider context - a
/// global preference (`AppSettings.extendedContextDisplayMode`), not a
/// per-document one, since it's purely about presentation, not data.
enum ExtendedContextDisplayMode: String, Codable {
    /// An independent, non-modal window
    /// (`ExtendedContextWindowController`) - the original 6.6 behavior
    /// was a modal sheet; switched to a plain window once multiple could
    /// need to stay open at once (`AppSettings
    /// .allowMultipleExtendedContexts`), which a sheet can't support (at
    /// most one per parent window). Kept the `sheet` case name/rawValue
    /// for UserDefaults backward compatibility - the Settings UI now
    /// labels it "Window".
    case sheet
    /// The clicked row itself grows in place into a word-wrapped
    /// paragraph, right in the table - added after the user asked for it
    /// as an alternative to the sheet.
    case inline
}

/// The persisted content is the query, not the materialized rows - stable
/// and small regardless of result-set size, and the base that the
/// `operations` chain (see `ConcordanceOperation`) replays against. See
/// docs/project-plan.md's NSDocument model section.
final class ConcordanceDocument: NSDocument {
    static let typeName = "cz.cuni.mff.ufal.korpora.concordance"

    var corpusName: String = ""
    /// Path to a subcorpus (see `SubcorpusStore`) to query instead of the
    /// whole corpus, or nil to query `corpusName` directly.
    var subcorpusPath: String?
    var initialQuery: String = ""
    // Defaults come from AppSettings (Phase 6.4's Concordance settings
    // tab) at instance-creation time - correct for both a brand-new
    // document (nothing else sets these beforehand) and a reopened saved
    // one (`read(from:)` immediately overwrites them anyway).
    var leftContext = "-\(AppSettings.shared.defaultLeftContext)"
    var rightContext = "\(AppSettings.shared.defaultRightContext)"
    /// See `ConcordanceViewMode`. `leftContext`/`rightContext` themselves
    /// are left untouched by this - `effectiveLeftContext`/
    /// `.effectiveRightContext` (what's actually sent to the engine)
    /// override them to a structure-aligned spec in `.sentence` mode, so
    /// switching back to `.kwic` trivially restores whatever numeric
    /// width was last set via `setContext`, with no separate "remembered
    /// width" state needed.
    private(set) var viewMode: ConcordanceViewMode = AppSettings.shared.defaultViewMode
    var kwicAttr = "word"
    /// Additional positional attributes (e.g. "lemma", "tag") shown
    /// alongside `kwicAttr` per token - see `KWICFormatter`. Independent,
    /// not an either/or mode: an attribute can be in both lists at once
    /// (shown inline *and* repeated in the hover tooltip), one only, or
    /// neither. Both empty by default: no visual change from before this
    /// feature existed.
    var inlineAttributes: [String] = []
    var tooltipAttributes: [String] = []
    /// A structural attribute (e.g. "doc.title") shown as its own column
    /// on every row - constant for the whole line (one enclosing document
    /// per hit), unlike `inlineAttributes`/`tooltipAttributes` which vary
    /// per token, so this doesn't feed `attributesToFetch`/`KWICFormatter`
    /// at all - it's fetched separately per row in `buildRows`. There's
    /// only ever one "Doc" column, so this is a single value, not a list
    /// - see `AttributeDisplayPopoverController`'s radio-button choice.
    var structuralAttributeToShow: String?

    /// The deduplicated union of both lists, in first-seen order - what
    /// actually needs fetching from the engine, since both lists need real
    /// per-token values regardless of which one(s) an attribute is in.
    private var attributesToFetch: [String] {
        var seen = Set<String>()
        return (inlineAttributes + tooltipAttributes).filter { seen.insert($0).inserted }
    }

    private(set) var operations: [ConcordanceOperation] = []
    private(set) var rows: [ConcordanceRow] = []
    private(set) var status: String = ""

    /// The `LiveConcordance` behind the most recently *successful* replay -
    /// kept around (rather than discarded once `rows` is fetched, as before)
    /// so Phase 3 features (collocations, frequency distributions) have a
    /// live handle reflecting the document's current sort/filter/sample/
    /// line-group state to run against, without re-executing the whole
    /// operation chain from scratch. `nil` before the first successful query
    /// and after a failed replay (see `replay()`'s catch branch).
    private var liveConcordance: LiveConcordance?

    /// The `Corpus` (or opened subcorpus) behind the most recent successful
    /// replay - kept around, same reasoning as `liveConcordance`, so
    /// `structuralInfo(at:)` can look up a specific hit's enclosing
    /// structural attributes (e.g. "doc.author") on demand later, without
    /// needing a live `LiveConcordance`/iterator (structural lookups are
    /// pure `Corpus`-level position queries - see `KWICLine.position`).
    private var queryCorpus: Corpus?

    /// Once any line-group operation exists, sort/filter/shuffle/sample are
    /// disabled - mirrors KonText's own mutual-exclusion rule, since a fresh
    /// sort/sample would silently invalidate the view line-group
    /// assignments are keyed to (Manatee resets/discards the view on some of
    /// those operations - see `LiveConcordance.sample`'s doc comment).
    var hasLineGroups: Bool { operations.contains { $0.isLineGroupOperation } }

    /// The view controller sets this to learn when `rows`/`status` change.
    /// `animated` is false for a display-only refetch (`refetchDisplay()`,
    /// behind `setContext`/`setAttributeDisplay`) - animating a diffable
    /// snapshot apply while a toolbar popover is *also* closing (its own
    /// Core Animation transition) raced with that transition and produced
    /// "Invalid attempt to open a new transaction during CA commit"
    /// warnings, found via manual testing 2026-09-07. A display-only
    /// refetch never adds/removes/reorders rows anyway - only their
    /// content changes - so there's nothing worth animating here even
    /// setting the bug aside.
    var onResultsChanged: ((_ animated: Bool) -> Void)?

    private weak var windowController: ConcordanceWindowController?

    override class var autosavesInPlace: Bool { true }

    /// A concordance is disposable scratch state by default - like a
    /// KonText tab, not a file the user must explicitly keep or discard.
    /// NSDocument's default `isDocumentEdited` tracks the undo manager, and
    /// every `setOperations` call (sort/filter/shuffle/sample/line-group)
    /// registers an undo action - so without this override, touching any
    /// toolbar control would dirty the document and closing/quitting would
    /// prompt to Save/Delete/Cancel. Explicit File > Save still works (see
    /// `validateUserInterfaceItem` below), independent of this override.
    override var isDocumentEdited: Bool { false }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSDocument.save(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func makeWindowControllers() {
        let controller = ConcordanceWindowController(document: self)
        windowController = controller
        addWindowController(controller)
        if initialQuery.isEmpty {
            // A brand-new, parameterless document - ask for a corpus + CQL
            // query once the window has actually been shown (AppKit calls
            // `showWindows()` right after this method returns, whether the
            // document was created via our own code or its own automatic
            // untitled-document-at-launch path).
            DispatchQueue.main.async { [weak self] in self?.presentNewConcordanceSheet() }
        } else {
            replay()
        }
    }

    /// Presents the corpus/query picker for a brand-new document.
    func presentNewConcordanceSheet() {
        guard let contentViewController = windowController?.window?.contentViewController else { return }
        let sheet = NewConcordanceSheetController()
        sheet.corpusName = corpusName
        sheet.query = initialQuery
        sheet.onCommit = { [weak self] corpus, subcorpusPath, cql in
            guard let self else { return }
            corpusName = corpus
            self.subcorpusPath = subcorpusPath
            runQuery(cql)
        }
        sheet.onCancel = { [weak self] in
            guard let self, initialQuery.isEmpty else { return }
            windowController?.close()
        }
        contentViewController.presentAsSheet(sheet)
    }

    /// Runs a brand-new query, discarding any operation chain - used for the
    /// initial "New Concordance" sheet and for re-running the query bar.
    func runQuery(_ cql: String) {
        initialQuery = cql
        operations = []
        // Recorded unconditionally (see QueryHistoryStore's doc comment) -
        // this covers both the initial "New Concordance" sheet's Search
        // button (which sets corpusName/subcorpusPath then calls this) and
        // the persistent query bar's re-run, with no separate call site
        // needed at either.
        QueryHistoryStore.record(corpusName: corpusName, subcorpusPath: subcorpusPath, query: cql)
        replay()
    }

    // MARK: - Operations (each undoable - see `ConcordanceOperation`)

    func performSort(_ criteria: SortCriteria, unique: Bool = false, descending: Bool = false) {
        appendOperation(.sort(criteria, unique: unique, descending: descending))
    }

    func performFilter(_ spec: PNFilterSpec) {
        appendOperation(.filter(spec))
    }

    func performShuffle() {
        appendOperation(.shuffle)
    }

    func performSample(lines: Int) {
        appendOperation(.sample(lines: lines))
    }

    func performSetLineGroup(rangeStart: Int, rangeLen: Int, group: Int) {
        appendOperation(.setLineGroup(rangeStart: rangeStart, rangeLen: rangeLen, group: group))
    }

    /// Assigns every given row to `group` as a single operation-chain update.
    /// Must be used instead of calling `performSetLineGroup` once per row -
    /// each call to `appendOperation` triggers its own `replay()`, and
    /// `replay()` opens a brand-new `Corpus`/`LiveConcordance` (a fresh
    /// Manatee handle) - firing one per selected row let multiple overlapping
    /// handles hit the engine concurrently and crashed it.
    func performSetLineGroups(_ rangeStarts: [Int], group: Int) {
        guard !rangeStarts.isEmpty else { return }
        let ops = rangeStarts.map { ConcordanceOperation.setLineGroup(rangeStart: $0, rangeLen: 1, group: group) }
        setOperations(operations + ops)
    }

    /// Drops every `.setLineGroup` operation assigning `group` specifically
    /// (every other group's assignments are untouched) and replays - lines
    /// whose only assignment was to `group` revert to no group (Manatee's
    /// own default); a line reassigned to a different group afterward is
    /// unaffected, since its later operation is what's actually still in
    /// effect. Safe to filter by group number alone, ignoring position,
    /// because the toolbar disables sort/filter/shuffle/sample once any
    /// line group exists - every `.setLineGroup` operation in the chain
    /// therefore runs against the same, unchanging view order.
    func performClearLineGroup(_ group: Int) {
        setOperations(operations.filter {
            guard case .setLineGroup(_, _, let g) = $0 else { return true }
            return g != group
        })
    }

    /// Removes exactly one operation from the chain (e.g. a single sort or
    /// filter from the Operations popover) and replays the rest - more
    /// targeted than Undo, which can only unwind the most recent operation.
    /// `index` is into the full `operations` array, not a filtered display
    /// list, so callers showing a subset (see `OperationsPopoverController`)
    /// must track true indices themselves.
    func removeOperation(at index: Int) {
        guard operations.indices.contains(index) else { return }
        var newOperations = operations
        newOperations.remove(at: index)
        setOperations(newOperations)
    }

    private func appendOperation(_ op: ConcordanceOperation) {
        setOperations(operations + [op])
    }

    private func setOperations(_ newOperations: [ConcordanceOperation]) {
        let previous = operations
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.setOperations(previous)
        }
        operations = newOperations
        replay()
    }

    // MARK: - Query execution

    /// Chains onto any in-flight replay instead of letting two run
    /// concurrently - each `replay()` opens its own `Corpus`/`LiveConcordance`
    /// (a fresh Manatee handle), and the engine's thread-safety under
    /// concurrent access from separate handles is undocumented (see
    /// `LiveConcordance`'s doc comment). Two operations queued back-to-back
    /// before the first query resolves (e.g. `performSetLineGroups`, or any
    /// future rapid double-action) would otherwise fire concurrently.
    private var currentReplayTask: Task<Void, Never>?

    /// Widens/narrows how many tokens of left/right context each KWIC line
    /// shows, in an already-open window - matches KonText's own live
    /// expand/narrow-context control. Unlike sort/filter/shuffle/sample,
    /// this is purely a display setting (mirrors `kwicAttr`): not part of
    /// the undoable `operations` chain, and doesn't require or invalidate
    /// line groups, since it can't change which hits exist or their order.
    func setContext(left: Int, right: Int) {
        leftContext = "-\(max(left, 0))"
        rightContext = "\(max(right, 0))"
        refetchDisplay()
    }

    /// What's actually sent to the engine for left/right context - see
    /// `ConcordanceViewMode`. `-1:s`/`1:s` are manatee-open's own
    /// Bonito/Sketch-Engine-style context-spec syntax for "expand to the
    /// enclosing `<s>` boundary" (confirmed in `concord/concctx.cc`),
    /// already supported end-to-end since `leftContext`/`rightContext`
    /// were free-form strings, not parsed integers, from the start.
    private var effectiveLeftContext: String { viewMode == .sentence ? "-1:s" : leftContext }
    private var effectiveRightContext: String { viewMode == .sentence ? "1:s" : rightContext }

    /// KWIC vs. Sentence - same "pure display setting" status as
    /// `setContext`. Toggling this back to `.kwic` needs no bookkeeping
    /// of its own to restore the previous numeric width: `leftContext`/
    /// `rightContext` were never touched while in `.sentence` mode (see
    /// `effectiveLeftContext`/`.effectiveRightContext`).
    func setViewMode(_ mode: ConcordanceViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        refetchDisplay()
    }

    /// Which secondary positional attributes (e.g. "lemma"/"tag") to show
    /// inline vs. in a hover tooltip - independent per attribute (an
    /// attribute can be in both, one, or neither list; see
    /// `inlineAttributes`/`tooltipAttributes`'s own doc comment). Same
    /// "pure display setting" status as `setContext`, for the same reason:
    /// it can't change which hits exist, their order, or their line
    /// groups, only how each already-fetched hit is annotated.
    func setAttributeDisplay(inlineAttributes: [String], tooltipAttributes: [String]) {
        self.inlineAttributes = inlineAttributes
        self.tooltipAttributes = tooltipAttributes
        refetchDisplay()
    }

    /// Which structural attribute (e.g. "doc.title"), if any, to show as
    /// its own column on every row - same "pure display setting" status
    /// as `setContext`/`setAttributeDisplay`.
    func setStructuralAttributeDisplay(_ attribute: String?) {
        structuralAttributeToShow = attribute
        refetchDisplay()
    }

    /// Re-fetches KWIC lines from the existing `liveConcordance` handle
    /// using the document's *current* leftContext/rightContext/kwicAttr/
    /// attributesToFetch - cheaper than `replay()`, which would reopen the
    /// corpus and re-run the whole query/operation chain from scratch just
    /// to change how already-fetched hits are displayed. No-op if no query
    /// has run yet (`liveConcordance` is nil) - the next `replay()` will
    /// pick up whatever's currently stored regardless. `status`'s
    /// hit-count/corpus-size text is left as-is, since neither changes from
    /// a display-only refetch.
    private func refetchDisplay() {
        guard liveConcordance != nil else { return }
        let leftContext = effectiveLeftContext
        let rightContext = effectiveRightContext
        let kwicAttr = kwicAttr
        let secondaryAttributes = attributesToFetch
        let structuralAttributeToShow = structuralAttributeToShow
        let descendingSort = Self.descendingSort(in: operations)
        let previousReplay = currentReplayTask
        currentReplayTask = Task { @MainActor in
            await previousReplay?.value
            guard let live = liveConcordance, let queryCorpus else { return }
            do {
                let lines = try await live.kwicLines(
                    leftContext: leftContext, rightContext: rightContext, kwicAttr: kwicAttr,
                    secondaryAttributes: secondaryAttributes)
                rows = await Self.buildRows(
                    from: lines, live: live, descendingSort: descendingSort,
                    queryCorpus: queryCorpus, structuralAttributeToShow: structuralAttributeToShow)
            } catch {
                status = "\(error)"
            }
            onResultsChanged?(false)
        }
    }

    private func replay() {
        guard !corpusName.trimmingCharacters(in: .whitespaces).isEmpty,
              !initialQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        status = "Searching…"
        onResultsChanged?(true)
        let corpusName = corpusName
        let subcorpusPath = subcorpusPath
        let query = initialQuery
        let leftContext = effectiveLeftContext
        let rightContext = effectiveRightContext
        let kwicAttr = kwicAttr
        let secondaryAttributes = attributesToFetch
        let structuralAttributeToShow = structuralAttributeToShow
        let operations = operations
        let descendingSort = Self.descendingSort(in: operations)
        let previousReplay = currentReplayTask
        currentReplayTask = Task { @MainActor in
            await previousReplay?.value
            do {
                let corpus = try Corpus(name: corpusName)
                let queryCorpus: Corpus
                if let subcorpusPath {
                    queryCorpus = try await corpus.openSubcorpus(atPath: subcorpusPath)
                } else {
                    queryCorpus = corpus
                }
                let live = try await LiveConcordance(corpus: queryCorpus, cql: query)
                for op in operations {
                    try await op.apply(to: live)
                }
                // search size, not the parent corpus's - openSubcorpus already
                // makes this correctly reflect the restricted token count.
                let corpusSize = try await queryCorpus.size
                let lines = try await live.kwicLines(
                    leftContext: leftContext, rightContext: rightContext, kwicAttr: kwicAttr,
                    secondaryAttributes: secondaryAttributes)
                rows = await Self.buildRows(
                    from: lines, live: live, descendingSort: descendingSort,
                    queryCorpus: queryCorpus, structuralAttributeToShow: structuralAttributeToShow)
                liveConcordance = live
                self.queryCorpus = queryCorpus
                let corpusDescription: String
                if let subcorpusPath {
                    let subcorpusName = (subcorpusPath as NSString).lastPathComponent
                        .replacingOccurrences(of: ".subc", with: "")
                    corpusDescription = "\(corpusSize)-token subcorpus “\(subcorpusName)”"
                } else {
                    corpusDescription = "\(corpusSize)-token corpus"
                }
                status = "\(lines.count) hit\(lines.count == 1 ? "" : "s") in a \(corpusDescription)"
            } catch {
                rows = []
                liveConcordance = nil
                queryCorpus = nil
                status = "\(error)"
            }
            onResultsChanged?(true)
        }
    }

    /// The most recent `.sort` operation's `descending` flag - later
    /// operations (e.g. a filter after a descending sort) don't reset it,
    /// matching how only a fresh `.sort` operation itself changes it.
    private static func descendingSort(in operations: [ConcordanceOperation]) -> Bool {
        operations.reversed().lazy.compactMap { op -> Bool? in
            if case .sort(_, _, let descending) = op { return descending }
            return nil
        }.first ?? false
    }

    /// Looks up each line's group (keyed to Manatee's own view order, via
    /// `live.linegroup(at:)`) before applying `descendingSort`'s
    /// display-only reversal - Manatee's own sort is always ascending (see
    /// `ConcordanceOperation.sort`'s doc comment), so descending is purely a
    /// display-order flip; `id` (== the row's index, per
    /// `ConcordanceViewController.makeCell`) is reassigned to match the
    /// flipped positions. Fans every row's `linegroup(at:)` lookup (and,
    /// if `structuralAttributeToShow` isn't nil, its structural attribute
    /// lookup - see `ConcordanceRow.structuralAttributeValue`) out
    /// concurrently via a `TaskGroup`, rather than one `await` per row in
    /// sequence - both are per-row engine round trips, so this matters
    /// more the more rows there are.
    private static func buildRows(
        from lines: [KWICLine], live: LiveConcordance, descendingSort: Bool,
        queryCorpus: Corpus, structuralAttributeToShow: String?
    ) async -> [ConcordanceRow] {
        var newRows = [ConcordanceRow?](repeating: nil, count: lines.count)
        await withTaskGroup(of: (Int, ConcordanceRow).self) { group in
            for (offset, line) in lines.enumerated() {
                group.addTask {
                    let lineGroup = await live.linegroup(at: offset)
                    var structuralValue: String?
                    if let attribute = structuralAttributeToShow,
                       let value = try? await queryCorpus.structuralAttributeValue(at: line.position, attribute: attribute),
                       !value.isEmpty {
                        structuralValue = value
                    }
                    return (offset, ConcordanceRow(
                        id: offset, line: line, group: lineGroup, structuralAttributeValue: structuralValue))
                }
            }
            for await (offset, row) in group {
                newRows[offset] = row
            }
        }
        var result = newRows.compactMap { $0 }
        if descendingSort {
            result = result.reversed().enumerated().map { i, row in
                ConcordanceRow(id: i, line: row.line, group: row.group, structuralAttributeValue: row.structuralAttributeValue)
            }
        }
        return result
    }

    // MARK: - Analysis (collocations, frequency distributions)

    enum AnalysisError: Error, CustomStringConvertible {
        case noResultsYet
        var description: String {
            switch self {
            case .noResultsYet: return "Run a query first."
            }
        }
    }

    /// Top collocates of the current query's hits - see `CollocationSpec`.
    /// Reflects whatever sort/filter/sample/line-groups are currently
    /// applied, since it runs against `liveConcordance` directly rather than
    /// replaying the operation chain again.
    func collocations(_ spec: CollocationSpec) async throws -> [CollocationItem] {
        guard let liveConcordance else { throw AnalysisError.noResultsYet }
        return try await liveConcordance.collocations(spec)
    }

    /// Frequency distribution of the current query's hits - see
    /// `FrequencyCriterion`. Same "reflects the current view" behavior as
    /// `collocations(_:)`.
    func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int = 1) async throws -> [FrequencyItem] {
        guard let liveConcordance else { throw AnalysisError.noResultsYet }
        return try await liveConcordance.frequencyDistribution(criteria, minFrequency: minFrequency)
    }

    /// One structural attribute value (e.g. "doc.author" → "Twain") enclosing
    /// `rowID`'s hit - every attribute of every structure the corpus
    /// declares, skipping any that come back empty (not enclosed by that
    /// structure at this position, or genuinely blank). Unlike
    /// `collocations`/`frequencyDistribution`, this only needs `queryCorpus`
    /// (a plain position lookup - see `KWICLine.position`), not
    /// `liveConcordance`, so it keeps working even if a later sort/filter
    /// replaced the live handle, as long as the row itself is still there.
    func structuralInfo(at rowID: Int) async throws -> [(structure: String, attribute: String, value: String)] {
        guard let queryCorpus else { throw AnalysisError.noResultsYet }
        guard rows.indices.contains(rowID) else { return [] }
        let position = rows[rowID].line.position
        let info = try await queryCorpus.info()
        var results: [(structure: String, attribute: String, value: String)] = []
        for structure in info.structures {
            for attribute in structure.attributes {
                let value = try await queryCorpus.structuralAttributeValue(
                    at: position, attribute: "\(structure.name).\(attribute)")
                guard !value.isEmpty else { continue }
                results.append((structure.name, attribute, value))
            }
        }
        return results
    }

    /// One hit's match plus much wider surrounding context than its table
    /// row shows - KonText's "concordance detail" (Phase 6.6). Fetches
    /// directly via `Corpus.positionalAttributeRange` (Phase 5.4/6.6's
    /// position-indexed lookup pattern), independent of
    /// `leftContext`/`rightContext`/`viewMode` entirely - a much wider
    /// window than either would reasonably show inline, and unaffected by
    /// whichever one is currently active. `AppSettings.shared
    /// .defaultExtendedContextTokens` (Phase 6.4) sets how many tokens
    /// each side to ask for; a hit near the very start/end of the corpus
    /// gets fewer on that side (the bridge clamps the fetch, this clamps
    /// the "how many words precede the match" math identically, so the
    /// split into before/match/after stays correct either way).
    func extendedContext(at rowID: Int) async throws -> (before: String, match: String, after: String) {
        guard let queryCorpus else { throw AnalysisError.noResultsYet }
        guard rows.indices.contains(rowID) else { throw AnalysisError.noResultsYet }
        let line = rows[rowID].line
        let matchLength = max(line.kwicTokens.count, 1)
        let tokensAround = AppSettings.shared.defaultExtendedContextTokens
        let position = line.position
        let actualTokensBefore = min(tokensAround, position)
        let text = try await queryCorpus.positionalAttributeRange(
            from: position - tokensAround, to: position + matchLength + tokensAround, attribute: kwicAttr)
        let words = text.split(separator: " ").map(String.init)
        let before = words.prefix(actualTokensBefore).joined(separator: " ")
        let match = words.dropFirst(actualTokensBefore).prefix(matchLength).joined(separator: " ")
        let after = words.dropFirst(actualTokensBefore + matchLength).joined(separator: " ")
        return (before, match, after)
    }

    /// Identifies which hit an `ExtendedContextWindowController` belongs
    /// to - the corpus name is always known; document/sentence labels are
    /// whichever structural attribute values `structuralInfo(at:)` (every
    /// non-empty structure/attribute enclosing this position) happens to
    /// have, reusing that lookup rather than querying the engine again:
    /// document is whichever entry matches `structuralAttributeToShow`
    /// (the same attribute already shown as its own KWIC column, if any);
    /// sentence is the first attribute of a structure literally named
    /// "s" (the common corpus convention for the enclosing sentence),
    /// falling back to nil if the corpus declares no such structure.
    struct ExtendedContextInfo {
        let corpusName: String
        let documentLabel: String?
        let sentenceLabel: String?

        var headerLines: [String] {
            var lines = ["Corpus: \(corpusName)"]
            if let documentLabel { lines.append("Document: \(documentLabel)") }
            if let sentenceLabel { lines.append("Sentence: \(sentenceLabel)") }
            return lines
        }
    }

    func extendedContextInfo(at rowID: Int) async throws -> ExtendedContextInfo {
        let info = try await structuralInfo(at: rowID)
        let documentLabel = structuralAttributeToShow.flatMap { attribute in
            info.first { "\($0.structure).\($0.attribute)" == attribute }
                .map { "\($0.attribute): \($0.value)" }
        }
        let sentenceLabel = info.first { $0.structure == "s" }.map { "\($0.attribute): \($0.value)" }
        return ExtendedContextInfo(corpusName: corpusName, documentLabel: documentLabel, sentenceLabel: sentenceLabel)
    }

    // MARK: - Persistence (query + operation chain only, never the materialized rows)

    private struct DocumentState: Codable {
        var corpusName: String
        var subcorpusPath: String?
        var initialQuery: String
        var leftContext: String
        var rightContext: String
        var kwicAttr: String
        // Optional (not defaulted-non-optional) so a document autosaved
        // before these existed still decodes - a missing key becomes nil
        // for an Optional property under Codable's synthesized decoding,
        // with no custom init needed.
        var inlineAttributes: [String]?
        var tooltipAttributes: [String]?
        // Already optional at the live-property level too (nil == "None"
        // is a real, meaningful value here, not just "unset") - Codable's
        // synthesized decoding already treats a missing key as nil for an
        // Optional property, so no `?? []`-style fallback is needed.
        var structuralAttributeToShow: String?
        // Missing key (a document saved before this existed) decodes to
        // nil, not `.kwic` directly - `read(from:)` supplies that default
        // explicitly, same reasoning as `inlineAttributes ?? []` below.
        var viewMode: ConcordanceViewMode?
        var operations: [ConcordanceOperation]
    }

    override func data(ofType typeName: String) throws -> Data {
        let state = DocumentState(
            corpusName: corpusName, subcorpusPath: subcorpusPath, initialQuery: initialQuery,
            leftContext: leftContext, rightContext: rightContext, kwicAttr: kwicAttr,
            inlineAttributes: inlineAttributes, tooltipAttributes: tooltipAttributes,
            structuralAttributeToShow: structuralAttributeToShow, viewMode: viewMode,
            operations: operations)
        return try JSONEncoder().encode(state)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let state = try JSONDecoder().decode(DocumentState.self, from: data)
        corpusName = state.corpusName
        subcorpusPath = state.subcorpusPath
        initialQuery = state.initialQuery
        leftContext = state.leftContext
        rightContext = state.rightContext
        kwicAttr = state.kwicAttr
        inlineAttributes = state.inlineAttributes ?? []
        tooltipAttributes = state.tooltipAttributes ?? []
        structuralAttributeToShow = state.structuralAttributeToShow
        viewMode = state.viewMode ?? .kwic
        operations = state.operations
    }
}
