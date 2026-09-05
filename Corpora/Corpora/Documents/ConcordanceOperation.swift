import ManateeKit

/// The replayable recipe for a concordance: the initial query plus every
/// sort/filter/shuffle/sample/line-group operation applied since, in order.
/// This - not the materialized rows - is what gets persisted and what
/// `NSUndoManager` tracks; Manatee's `Concordance` can't remove an operation
/// from the middle of a chain, only replay from the start, so undo rebuilds
/// through the first N-1 operations against a fresh `LiveConcordance`
/// rather than inverting the Nth one (see `ConcordanceDocument.setOperations`).
enum ConcordanceOperation: Codable {
    case sort(SortCriteria, unique: Bool)
    case filter(PNFilterSpec)
    case shuffle
    case sample(lines: Int)
    case setLineGroup(rangeStart: Int, rangeLen: Int, group: Int)

    var isLineGroupOperation: Bool {
        if case .setLineGroup = self { return true }
        return false
    }

    func apply(to live: LiveConcordance) async throws {
        switch self {
        case .sort(let criteria, let unique):
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
