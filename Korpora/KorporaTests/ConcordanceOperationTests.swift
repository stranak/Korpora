import Foundation
import Testing
import ManateeKit
@testable import Korpora

@Suite struct ConcordanceOperationTests {
    @Test func lineGroupOperationIsRecognized() {
        let setGroup = ConcordanceOperation.setLineGroup(rangeStart: 0, rangeLen: 1, group: 1)
        #expect(setGroup.isLineGroupOperation)

        let shuffle = ConcordanceOperation.shuffle
        #expect(!shuffle.isLineGroupOperation)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = ConcordanceOperation.sample(lines: 50)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConcordanceOperation.self, from: data)
        #expect(!decoded.isLineGroupOperation)
    }

    @Test func singleLevelSortExposesLevelAndDirection() throws {
        let level = SortLevel(attribute: "word", anchor: .kwic)
        let op = ConcordanceOperation.sort(SortCriteria(level), unique: false, descending: true)
        let extracted = try #require(op.singleLevelSort)
        #expect(extracted.level.attribute == "word")
        #expect(extracted.level.anchor == .kwic)
        #expect(extracted.descending)
    }

    @Test func multiLevelSortHasNoSingleLevelSort() {
        let criteria = SortCriteria(levels: [
            SortLevel(attribute: "word", anchor: .kwic),
            SortLevel(attribute: "lemma", anchor: .left),
        ])
        let op = ConcordanceOperation.sort(criteria, unique: false, descending: false)
        #expect(op.singleLevelSort == nil)
    }

    @Test func sortDescendingRoundTripsThroughJSON() throws {
        let original = ConcordanceOperation.sort(
            SortCriteria(SortLevel(attribute: "word", anchor: .left)), unique: true, descending: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConcordanceOperation.self, from: data)
        let extracted = try #require(decoded.singleLevelSort)
        #expect(extracted.descending)
    }

    @Test func summaryDescribesEachOperationKind() {
        let sort = ConcordanceOperation.sort(
            SortCriteria(SortLevel(attribute: "word", anchor: .kwic)), unique: false, descending: false)
        #expect(sort.summary == "Sort: word at Match, ascending")

        let filter = ConcordanceOperation.filter(PNFilterSpec(positive: true, query: #"[word="fox"]"#))
        #expect(filter.summary == #"Filter: keep lines matching [word="fox"]"#)

        #expect(ConcordanceOperation.shuffle.summary == "Shuffle")
        #expect(ConcordanceOperation.sample(lines: 1).summary == "Sample: 1 line")
        #expect(ConcordanceOperation.sample(lines: 5).summary == "Sample: 5 lines")
    }

    // `ConcordanceDocument.replay()` no-ops when corpusName/initialQuery are
    // empty, so a bare `ConcordanceDocument()` - with no corpus, window, or
    // MANATEE_REGISTRY - is enough to test the operations-array bookkeeping
    // itself, independent of the engine.
    @Test func removeOperationDropsExactlyOneAndKeepsOrder() {
        let doc = ConcordanceDocument()
        doc.performSort(SortCriteria(SortLevel(attribute: "word", anchor: .kwic)))
        doc.performSample(lines: 10)
        doc.performShuffle()
        #expect(doc.operations.count == 3)

        doc.removeOperation(at: 1)
        #expect(doc.operations.map(\.summary) == ["Sort: word at Match, ascending", "Shuffle"])
    }

    @Test func removeOperationIgnoresOutOfBoundsIndex() {
        let doc = ConcordanceDocument()
        doc.performSample(lines: 10)
        doc.removeOperation(at: 5)
        #expect(doc.operations.count == 1)
    }
}
