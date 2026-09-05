import Foundation
import Testing
import ManateeKit
@testable import Corpora

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
}
