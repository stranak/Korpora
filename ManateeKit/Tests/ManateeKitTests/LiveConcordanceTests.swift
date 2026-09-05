import XCTest

@testable import ManateeKit

/// Covers the Phase 1 gap `ManateeKitTests` can't: composing several
/// operations (sort/shuffle/sample/filter/line-groups) on one *live*
/// concordance handle, rather than a fresh `Corpus.query(_:)` each time.
final class LiveConcordanceTests: XCTestCase {
    private static var fixture: TestCorpusFixture!

    override class func setUp() {
        super.setUp()
        do {
            fixture = try TestCorpusFixture.build()
        } catch {
            XCTFail("failed to build test corpus fixture: \(error)")
        }
    }

    override class func tearDown() {
        fixture?.cleanUp()
        fixture = nil
        super.tearDown()
    }

    private func makeLiveConcordance(_ cql: String = #"[tag="JJ"][tag="NN"]"#) async throws -> LiveConcordance {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        return try await LiveConcordance(corpus: corpus, cql: cql)
    }

    private func kwics(_ lines: [KWICLine]) -> [String] {
        // A collocation match (as `filter` sets up) adds its own empty
        // markup token to Manatee's KWIC output, which can widen the
        // existing leading-space quirk (see ManateeKitTests) into a
        // doubled *internal* space - collapse all runs of whitespace, since
        // the words themselves are what these tests care about.
        lines.map {
            $0.kwic.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    func testSortOrdersByKwicAttribute() async throws {
        let live = try await makeLiveConcordance()
        try await live.sort(SortCriteria(SortLevel(attribute: "word", anchor: .kwic)))
        let lines = try await live.kwicLines(leftContext: "-1", rightContext: "1")
        // Sorts on the match's first token (the JJ) alphabetically.
        XCTAssertEqual(kwics(lines), ["brown fox", "curious cat", "lazy dog", "sleepy cat"])
    }

    func testShuffleChangesOrderButPreservesLineSet() async throws {
        let live = try await makeLiveConcordance()
        let before = Set(kwics(try await live.kwicLines()))
        try await live.shuffle()
        let after = try await live.kwicLines()
        XCTAssertEqual(after.count, 4)
        XCTAssertEqual(Set(kwics(after)), before)
    }

    func testSampleReducesToRequestedCount() async throws {
        let live = try await makeLiveConcordance()
        try await live.sample(lines: 2)
        let lines = try await live.kwicLines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(Set(kwics(lines)).isSubset(of: ["brown fox", "lazy dog", "curious cat", "sleepy cat"]))
    }

    func testPositiveFilterKeepsOnlyMatchingLines() async throws {
        let live = try await makeLiveConcordance()
        // Sentences are only ~4-5 tokens apart, so a window narrow enough to
        // stay inside the current hit (its own 2 tokens) is what actually
        // isolates "dog" to the "lazy dog" match - a wider one (e.g. the
        // ±5-token default) leaks into neighboring sentences in a corpus
        // this small.
        try await live.filter(PNFilterSpec(positive: true, leftOffset: 0, rightOffset: 1, query: #"[word="dog"]"#))
        let lines = try await live.kwicLines(leftContext: "-1", rightContext: "1")
        XCTAssertEqual(kwics(lines), ["lazy dog"])
    }

    func testNegativeFilterExcludesMatchingLines() async throws {
        let live = try await makeLiveConcordance()
        try await live.filter(PNFilterSpec(positive: false, leftOffset: 0, rightOffset: 1, query: #"[word="dog"]"#))
        let lines = try await live.kwicLines(leftContext: "-1", rightContext: "1")
        XCTAssertEqual(kwics(lines), ["brown fox", "curious cat", "sleepy cat"])
    }

    func testLineGroupAssignmentRoundTrips() async throws {
        let live = try await makeLiveConcordance()
        try await live.setLineGroup(rangeStart: 0, rangeLen: 1, group: 3)
        try await live.setLineGroup(rangeStart: 2, rangeLen: 2, group: 5)

        var groups: [Int] = []
        for i in 0..<4 {
            groups.append(await live.linegroup(at: i))
        }
        XCTAssertEqual(groups, [3, 0, 5, 5])
    }

    func testDeleteLineGroupsKeepsOnlyRequestedGroups() async throws {
        let live = try await makeLiveConcordance()
        try await live.setLineGroup(rangeStart: 0, rangeLen: 1, group: 1)
        try await live.setLineGroup(rangeStart: 1, rangeLen: 1, group: 2)
        try await live.deleteLineGroups([1], invert: true)  // keep only group 1
        let lines = try await live.kwicLines(leftContext: "-1", rightContext: "1")
        XCTAssertEqual(kwics(lines), ["brown fox"])
    }

    /// The actual Phase 1 gap: today's `Corpus.query(_:)` re-queries from
    /// scratch every time and can't compose operations at all. This proves
    /// one live handle can carry a sort, then a filter, in sequence.
    func testOperationsComposeAcrossMultipleCalls() async throws {
        let live = try await makeLiveConcordance()
        try await live.sort(SortCriteria(SortLevel(attribute: "word", anchor: .kwic)))
        try await live.filter(PNFilterSpec(positive: false, leftOffset: 0, rightOffset: 1, query: #"[word="dog"]"#))
        let lines = try await live.kwicLines(leftContext: "-1", rightContext: "1")
        XCTAssertEqual(kwics(lines), ["brown fox", "curious cat", "sleepy cat"])
    }
}
