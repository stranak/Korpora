import Foundation

/// A single past query - `date` is when it was run. Persisted via
/// `UserDefaults` (mirrors `AppSettings`'s own precedent) rather than
/// `ManateeKit`, since this is purely app-level convenience state, not
/// anything the engine or a corpus registry needs to know about.
struct QueryHistoryEntry: Codable, Equatable {
    var corpusName: String
    var subcorpusPath: String?
    var query: String
    var date: Date
}

/// Recently run CQL queries, across every corpus/window - mirrors KonText's
/// own persistent query history rather than resetting every launch, since a
/// query worth re-running once is usually worth finding again later.
/// Recorded unconditionally at submission time (like shell history), not
/// only on a successful search - simpler, and "what did I just search for"
/// is still useful to recall even if it happened to be a CQL typo.
///
/// Entries are unique by (corpusName, subcorpusPath, query): re-running an
/// already-recorded query moves it to the front with a refreshed timestamp
/// instead of inserting a second entry - otherwise re-running a favorite
/// query from the History popover would just keep duplicating it at the
/// top rather than updating "last used," defeating the point of a
/// *history* (unique things done, most-recently-used first) versus a
/// plain append-only log.
enum QueryHistoryStore {
    private static let key = "queryHistory"
    /// Caps how many entries are kept - unbounded growth would make this
    /// slow to load/decode for no real benefit; a popover only ever shows
    /// the most recent handful anyway (see `HistoryPopoverController`).
    static let maxEntries = 200

    static let didChangeNotification = Notification.Name("QueryHistoryDidChange")

    static func recentEntries(defaults: UserDefaults = .standard) -> [QueryHistoryEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([QueryHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Records a query as just having been run. If an entry with the same
    /// (corpusName, subcorpusPath, query) already exists anywhere in the
    /// list, it's removed and reinserted at the front with `date` as its
    /// new timestamp - a "move to front + touch" upsert, not a plain
    /// append, so the list stays a set of unique queries ordered by last
    /// use rather than accumulating one row per run of the same query.
    static func record(
        corpusName: String, subcorpusPath: String?, query: String,
        date: Date = Date(), defaults: UserDefaults = .standard
    ) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var entries = recentEntries(defaults: defaults)
        entries.removeAll { $0.corpusName == corpusName && $0.subcorpusPath == subcorpusPath && $0.query == query }
        entries.insert(QueryHistoryEntry(corpusName: corpusName, subcorpusPath: subcorpusPath, query: query, date: date), at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
