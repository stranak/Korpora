import XCTest

@testable import ManateeKit

/// Covers `LiveConcordance.frequencyDistribution(_:minFrequency:)` (Phase 3)
/// against the shared fixture.
final class FrequencyDistributionTests: XCTestCase {
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

    private func makeLiveConcordance(_ cql: String) async throws -> LiveConcordance {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        return try await LiveConcordance(corpus: corpus, cql: cql)
    }

    /// `[tag="NN"]` hits: fox, dog, cat, cat - "cat" appears twice, the
    /// others once, so this also exercises the descending-frequency sort.
    func testFrequencyDistributionGroupsByWord() async throws {
        let live = try await makeLiveConcordance(#"[tag="NN"]"#)
        let items = try await live.frequencyDistribution([FrequencyCriterion(attribute: "word")])

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first?.word, "cat")
        XCTAssertEqual(items.first?.freq, 2)
        XCTAssertEqual(Set(items.dropFirst().map(\.word)), ["fox", "dog"])
        for item in items {
            XCTAssertNil(item.norm)
        }
    }

    func testFrequencyDistributionMinFrequencyFilters() async throws {
        let live = try await makeLiveConcordance(#"[tag="NN"]"#)
        let items = try await live.frequencyDistribution(
            [FrequencyCriterion(attribute: "word")], minFrequency: 2)
        XCTAssertEqual(items.map(\.word), ["cat"])
        XCTAssertEqual(items.map(\.freq), [2])
    }

    /// A structural attribute ("doc.id") makes `norm` meaningful - doc 1 has
    /// 9 tokens, doc 2 has 8, over the whole corpus.
    func testFrequencyDistributionByStructuralAttributePopulatesNorm() async throws {
        let live = try await makeLiveConcordance(#"[word=".*"]"#)
        let items = try await live.frequencyDistribution([FrequencyCriterion(attribute: "doc.id")])

        XCTAssertEqual(Set(items.map(\.word)), ["1", "2"])
        XCTAssertEqual(items.first { $0.word == "1" }?.freq, 9)
        XCTAssertEqual(items.first { $0.word == "2" }?.freq, 8)
        for item in items {
            XCTAssertNotNil(item.norm, "norm should be populated for a structural-attribute criterion")
        }
    }

    func testFrequencyDistributionThrowsForUnknownAttribute() async throws {
        let live = try await makeLiveConcordance(#"[tag="NN"]"#)
        do {
            _ = try await live.frequencyDistribution([FrequencyCriterion(attribute: "not_a_real_attr")])
            XCTFail("expected an error for an unknown attribute")
        } catch {
            // Expected.
        }
    }
}
