import Cocoa
import ManateeKit

struct ConcordanceRow {
    let id: Int
    let line: KWICLine
    let group: Int
}

/// The persisted content is the query, not the materialized rows - stable
/// and small regardless of result-set size, and the base that the
/// `operations` chain (see `ConcordanceOperation`) replays against. See
/// docs/project-plan.md's NSDocument model section.
final class ConcordanceDocument: NSDocument {
    static let typeName = "cz.cuni.mff.ufal.corpora.concordance"

    var corpusName: String = ""
    /// Path to a subcorpus (see `SubcorpusStore`) to query instead of the
    /// whole corpus, or nil to query `corpusName` directly.
    var subcorpusPath: String?
    var initialQuery: String = ""
    var leftContext = "-10"
    var rightContext = "10"
    var kwicAttr = "word"

    private(set) var operations: [ConcordanceOperation] = []
    private(set) var rows: [ConcordanceRow] = []
    private(set) var status: String = ""

    /// Once any line-group operation exists, sort/filter/shuffle/sample are
    /// disabled - mirrors KonText's own mutual-exclusion rule, since a fresh
    /// sort/sample would silently invalidate the view line-group
    /// assignments are keyed to (Manatee resets/discards the view on some of
    /// those operations - see `LiveConcordance.sample`'s doc comment).
    var hasLineGroups: Bool { operations.contains { $0.isLineGroupOperation } }

    /// The view controller sets this to learn when `rows`/`status` change.
    var onResultsChanged: (() -> Void)?

    private weak var windowController: ConcordanceWindowController?

    override class var autosavesInPlace: Bool { true }

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

    /// Drops every line-group operation and replays, returning to the normal
    /// sort/filter/shuffle/sample chain - Manatee has no "reset all labels
    /// but keep every line" call of its own to mirror instead.
    func performClearLineGroups() {
        setOperations(operations.filter { !$0.isLineGroupOperation })
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

    private func replay() {
        guard !corpusName.trimmingCharacters(in: .whitespaces).isEmpty,
              !initialQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        status = "Searching…"
        onResultsChanged?()
        let corpusName = corpusName
        let subcorpusPath = subcorpusPath
        let query = initialQuery
        let leftContext = leftContext
        let rightContext = rightContext
        let kwicAttr = kwicAttr
        let operations = operations
        // The most recent .sort operation's flag wins - later operations
        // (e.g. a filter after a descending sort) don't reset it, matching
        // how a fresh .sort operation is the only thing that changes it.
        let descendingSort = operations.reversed().lazy.compactMap { op -> Bool? in
            if case .sort(_, _, let descending) = op { return descending }
            return nil
        }.first ?? false
        Task { @MainActor in
            do {
                let corpus = try await Corpus(name: corpusName)
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
                let corpusSize = await queryCorpus.size
                let lines = try await live.kwicLines(
                    leftContext: leftContext, rightContext: rightContext, kwicAttr: kwicAttr)
                var newRows: [ConcordanceRow] = []
                newRows.reserveCapacity(lines.count)
                for (offset, line) in lines.enumerated() {
                    // linegroup(at:) is keyed to Manatee's own view order, so
                    // look it up before any display-only reversal below.
                    newRows.append(ConcordanceRow(id: offset, line: line, group: await live.linegroup(at: offset)))
                }
                if descendingSort {
                    // Manatee's own sort is always ascending (see
                    // ConcordanceOperation.sort's doc comment) - descending is
                    // purely a display-order flip, so `id` (== row.rows index,
                    // per ConcordanceViewController.makeCell) must be
                    // reassigned to match the new positions.
                    newRows = newRows.reversed().enumerated().map { i, row in
                        ConcordanceRow(id: i, line: row.line, group: row.group)
                    }
                }
                rows = newRows
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
                status = "\(error)"
            }
            onResultsChanged?()
        }
    }

    // MARK: - Persistence (query + operation chain only, never the materialized rows)

    private struct DocumentState: Codable {
        var corpusName: String
        var subcorpusPath: String?
        var initialQuery: String
        var leftContext: String
        var rightContext: String
        var kwicAttr: String
        var operations: [ConcordanceOperation]
    }

    override func data(ofType typeName: String) throws -> Data {
        let state = DocumentState(
            corpusName: corpusName, subcorpusPath: subcorpusPath, initialQuery: initialQuery,
            leftContext: leftContext, rightContext: rightContext, kwicAttr: kwicAttr,
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
        operations = state.operations
    }
}
