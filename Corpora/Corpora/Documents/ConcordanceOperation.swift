import ManateeKit

/// The replayable recipe for a concordance: the initial query plus every
/// sort/filter/shuffle/sample/line-group operation applied since, in order.
/// This - not the materialized rows - is what gets persisted and what
/// `NSUndoManager` tracks; Manatee's `Concordance` can't remove an operation
/// from the middle of a chain, only replay from the start, so undo rebuilds
/// through the first N-1 operations against a fresh `LiveConcordance`
/// rather than inverting the Nth one (see `ConcordanceDocument.setOperations`).
enum ConcordanceOperation: Codable {
    // `descending` isn't passed to Manatee - it has no native descending
    // sort (`LiveConcordance.sort` is always ascending), so this only flips
    // the final display order (see `ConcordanceDocument.replay()`). Column-
    // header clicks use this; the toolbar's Sort popover always sorts
    // ascending (`descending: false`), since it has no direction control.
    case sort(SortCriteria, unique: Bool, descending: Bool)
    case filter(PNFilterSpec)
    case shuffle
    case sample(lines: Int)
    case setLineGroup(rangeStart: Int, rangeLen: Int, group: Int)

    var isLineGroupOperation: Bool {
        if case .setLineGroup = self { return true }
        return false
    }

    /// The single-level attribute/anchor this operation sorts by, if it's a
    /// `.sort` case with exactly one level - used to sync column header
    /// indicators with whatever sort is actually active (from a header
    /// click, the toolbar popover, or after undo/redo). Multi-level or
    /// non-`word` sorts don't correspond to any header column.
    var singleLevelSort: (level: SortLevel, descending: Bool)? {
        guard case .sort(let criteria, _, let descending) = self,
              criteria.levels.count == 1, let level = criteria.levels.first else { return nil }
        return (level, descending)
    }

    func apply(to live: LiveConcordance) async throws {
        switch self {
        case .sort(let criteria, let unique, _):
            try await live.sort(criteria, unique: unique)
        case .filter(let spec):
            try await live.filter(spec)
        case .shuffle:
            try await live.shuffle()
        case .sample(let lines):
            try await live.sample(lines: lines)
        case .setLineGroup(let rangeStart, let rangeLen, let group):
            try await live.setLineGroup(rangeStart: rangeStart, rangeLen: rangeLen, group: group)
        }
    }
}
