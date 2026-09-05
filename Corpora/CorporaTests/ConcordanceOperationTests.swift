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
}
