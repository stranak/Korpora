import XCTest

@testable import ManateeKit

/// Phase 7 engine primitives for the natural-language query assistant
/// (docs/nl-query-assistant.md): cheap query validation, most frequent
/// attribute values, and registry lookups.
final class QueryAssistantSupportTests: XCTestCase {
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

    private func openFixture() async throws -> Corpus {
        try await Corpus(name: Self.fixture.corpusName)
    }

    // MARK: probeQuery

    /// brown fox, lazy dog, curious cat, sleepy cat.
    func testProbeCountsAllHitsUnderTheLimit() async throws {
        let corpus = try await openFixture()
        let count = try await corpus.probeQuery(#"[tag="JJ"][tag="NN"]"#, limit: 100)
        XCTAssertEqual(count, 4)
    }

    /// The point of the cap: the popover wants "at least N", not a full
    /// evaluation of a query that may match most of the corpus.
    func testProbeStopsAtTheLimit() async throws {
        let corpus = try await openFixture()
        let count = try await corpus.probeQuery(#"[tag="JJ"][tag="NN"]"#, limit: 2)
        XCTAssertEqual(count, 2)
    }

    /// limit 0 is validation only: a valid query returns 0, not its hits.
    func testProbeWithZeroLimitOnlyValidates() async throws {
        let corpus = try await openFixture()
        let count = try await corpus.probeQuery(#"[tag="JJ"]"#)
        XCTAssertEqual(count, 0)
    }

    /// A valid query with no hits is not an error.
    func testProbeOfAValidQueryWithNoHitsIsZero() async throws {
        let corpus = try await openFixture()
        let count = try await corpus.probeQuery(#"[word="zebra"]"#, limit: 10)
        XCTAssertEqual(count, 0)
    }

    /// The error the assistant feeds back to the model must carry the
    /// position - that's what lets a retry fix the right spot.
    func testProbeReportsSyntaxErrorsWithAPosition() async throws {
        let corpus = try await openFixture()
        do {
            _ = try await corpus.probeQuery(#"[tag="JJ""#)
            XCTFail("expected a syntax error")
        } catch ManateeError.failure(let message) {
            XCTAssertTrue(message.contains("position"), message)
        }
    }

    func testProbeRejectsUnknownAttributes() async throws {
        let corpus = try await openFixture()
        do {
            _ = try await corpus.probeQuery(#"[upos="NOUN"]"#)
            XCTFail("expected an unknown-attribute error")
        } catch ManateeError.failure(let message) {
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// Same filter_query as mtc_query, so the probe agrees with the real
    /// concordance size - including `within` restrictions.
    func testProbeAgreesWithTheConcordance() async throws {
        let corpus = try await openFixture()
        let cql = #"[tag="NN"] within <doc id="2"/>"#
        let probed = try await corpus.probeQuery(cql, limit: 1000)
        let concordance = try await LiveConcordance(corpus: corpus, cql: cql)
        let size = await concordance.size
        XCTAssertEqual(probed, 2)
        XCTAssertEqual(probed, size)
    }

    // MARK: topAttributeValues

    /// JJ 5; DT, NN, VBZ 4 each - ties in lexicon (first-seen) order.
    func testTopValuesAreSortedByFrequency() async throws {
        let corpus = try await openFixture()
        let top = try await corpus.topAttributeValues(attribute: "tag", limit: 10)
        XCTAssertEqual(top.map(\.value), ["JJ", "DT", "NN", "VBZ"])
        XCTAssertEqual(top.map(\.frequency), [5, 4, 4, 4])
    }

    func testTopValuesHonorTheLimit() async throws {
        let corpus = try await openFixture()
        let top = try await corpus.topAttributeValues(attribute: "tag", limit: 2)
        XCTAssertEqual(top.map(\.value), ["JJ", "DT"])
    }

    func testTopValuesOfAnUnknownAttributeThrow() async throws {
        let corpus = try await openFixture()
        do {
            _ = try await corpus.topAttributeValues(attribute: "upos", limit: 5)
            XCTFail("expected an unknown-attribute error")
        } catch ManateeError.failure {}
    }

    // MARK: registryValue

    func testRegistryValueReadsCorpusLevelKeys() async throws {
        let corpus = try await openFixture()
        let info = try await corpus.registryValue("INFO")
        XCTAssertEqual(info, "tiny smoke-test corpus")
    }

    /// Unset keys read as empty - the assistant treats TAGSETDOC/LABEL as
    /// optional hints, so absence must not be an error.
    func testRegistryValueOfAnUnsetKeyIsEmpty() async throws {
        let corpus = try await openFixture()
        let tagsetDoc = try await corpus.registryValue("TAGSETDOC")
        let label = try await corpus.registryValue("tag.LABEL")
        XCTAssertEqual(tagsetDoc, "")
        XCTAssertEqual(label, "")
    }

    func testRegistryValueThroughAnUnknownAttributeThrows() async throws {
        let corpus = try await openFixture()
        do {
            _ = try await corpus.registryValue("nosuch.LABEL")
            XCTFail("expected an error for a nonexistent attribute")
        } catch ManateeError.failure {}
    }
}
