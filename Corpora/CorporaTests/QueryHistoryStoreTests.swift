import Foundation
import Testing
@testable import Corpora

@Suite struct QueryHistoryStoreTests {
    /// A private, isolated suite per test - never touches the user's real
    /// `UserDefaults.standard` (which really does persist to disk).
    private func freshDefaults() -> UserDefaults {
        let suiteName = "QueryHistoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return defaults
    }

    @Test func recordAddsNewestFirst() {
        let defaults = freshDefaults()
        QueryHistoryStore.record(corpusName: "corpus1", subcorpusPath: nil, query: "[word=\"a\"]", date: Date(timeIntervalSince1970: 1), defaults: defaults)
        QueryHistoryStore.record(corpusName: "corpus1", subcorpusPath: nil, query: "[word=\"b\"]", date: Date(timeIntervalSince1970: 2), defaults: defaults)

        let entries = QueryHistoryStore.recentEntries(defaults: defaults)
        #expect(entries.map(\.query) == ["[word=\"b\"]", "[word=\"a\"]"])
    }

    @Test func recordMovesRepeatedQueryToFrontAndRefreshesItsTimestamp() {
        let defaults = freshDefaults()
        QueryHistoryStore.record(corpusName: "corpus1", subcorpusPath: nil, query: "[word=\"a\"]", date: Date(timeIntervalSince1970: 1), defaults: defaults)
        QueryHistoryStore.record(corpusName: "corpus1", subcorpusPath: nil, query: "[word=\"b\"]", date: Date(timeIntervalSince1970: 2), defaults: defaults)
        QueryHistoryStore.record(corpusName: "corpus1", subcorpusPath: nil, query: "[word=\"a\"]", date: Date(timeIntervalSince1970: 3), defaults: defaults)

        let entries = QueryHistoryStore.recentEntries(defaults: defaults)
        #expect(entries.map(\.query) == ["[word=\"a\"]", "[word=\"b\"]"])
        #expect(entries.first?.date == Date(timeIntervalSince1970: 3))
    }

    @Test func recordKeepsRepeatIfCorpusOrSubcorpusDiffers() {
        let defaults = freshDefaults()
        QueryHistoryStore.record(corpusName: "corpus1", subcorpusPath: nil, query: "[word=\"a\"]", defaults: defaults)
        QueryHistoryStore.record(corpusName: "corpus2", subcorpusPath: nil, query: "[word=\"a\"]", defaults: defaults)
        QueryHistoryStore.record(corpusName: "corpus2", subcorpusPath: "/tmp/sub.subc", query: "[word=\"a\"]", defaults: defaults)

        #expect(QueryHistoryStore.recentEntries(defaults: defaults).count == 3)
    }

    @Test func recordIgnoresBlankQueries() {
        let defaults = freshDefaults()
        QueryHistoryStore.record(corpusName: "corpus1", subcorpusPath: nil, query: "   ", defaults: defaults)
        #expect(QueryHistoryStore.recentEntries(defaults: defaults).isEmpty)
    }

    @Test func recordCapsAtMaxEntriesKeepingTheMostRecent() {
        let defaults = freshDefaults()
        for i in 0..<(QueryHistoryStore.maxEntries + 50) {
            QueryHistoryStore.record(
                corpusName: "corpus1", subcorpusPath: nil, query: "query-\(i)",
                date: Date(timeIntervalSince1970: Double(i)), defaults: defaults)
        }
        let entries = QueryHistoryStore.recentEntries(defaults: defaults)
        #expect(entries.count == QueryHistoryStore.maxEntries)
        #expect(entries.first?.query == "query-\(QueryHistoryStore.maxEntries + 49)")
    }

    @Test func clearRemovesEverything() {
        let defaults = freshDefaults()
        QueryHistoryStore.record(corpusName: "corpus1", subcorpusPath: nil, query: "[word=\"a\"]", defaults: defaults)
        QueryHistoryStore.clear(defaults: defaults)
        #expect(QueryHistoryStore.recentEntries(defaults: defaults).isEmpty)
    }
}
