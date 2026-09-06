import Foundation
import XCTest

@testable import ManateeKit

/// Covers `LiveConcordance.collocations(_:)` (Phase 3) against the shared
/// fixture. Uses `[tag="NN"]` (not the default `[JJ][NN]` two-token query
/// other tests share) so each hit is a single token, keeping the left/right
/// window arithmetic unambiguous.
final class CollocationTests: XCTestCase {
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

    private func makeLiveConcordance(_ cql: String = #"[tag="NN"]"#) async throws -> LiveConcordance {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        return try await LiveConcordance(corpus: corpus, cql: cql)
    }

    /// `[tag="NN"]` hits: fox, dog, cat (x2) - each preceded by a distinct,
    /// corpus-wide-unique adjective (brown/lazy/curious/sleepy), so every
    /// candidate has freq=1 (corpus-wide) and cnt=1 (co-occurs in exactly
    /// one of the 4 hit lines). logDice (`corp/bgrstat.cc`'s `bgr_log_dice`)
    /// is `14 + log2(2*f_AB/(f_A+f_B))` where f_AB=cnt, f_A=the collocate's
    /// own freq, and f_B is the *node* concordance's line count
    /// (`CollocItems::f_B` = `conc->viewsize()`) - 4 here, not the
    /// collocate's own frequency.
    func testCollocationsFindsLeftNeighbors() async throws {
        let live = try await makeLiveConcordance()
        let items = try await live.collocations(CollocationSpec(
            attribute: "word", measure: .logDice, leftWindow: -1, rightWindow: 0,
            minFrequency: 1, minCollocateFrequency: 1, maxItems: 10))

        XCTAssertEqual(Set(items.map(\.word)), ["brown", "lazy", "curious", "sleepy"])
        let expectedScore = 14.0 + log2(2.0 * 1.0 / (1.0 + 4.0))
        for item in items {
            XCTAssertEqual(item.freq, 1)
            XCTAssertEqual(item.cnt, 1)
            XCTAssertEqual(item.score, expectedScore, accuracy: 0.0001)
        }
    }

    func testCollocationsRespectMinCollocateFrequency() async throws {
        let live = try await makeLiveConcordance()
        // Every candidate here co-occurs exactly once - requiring at least
        // 2 co-occurrences should filter all of them out.
        let items = try await live.collocations(CollocationSpec(
            attribute: "word", leftWindow: -1, rightWindow: 0,
            minFrequency: 1, minCollocateFrequency: 2, maxItems: 10))
        XCTAssertEqual(items, [])
    }

    func testCollocationsRespectMaxItems() async throws {
        let live = try await makeLiveConcordance()
        let items = try await live.collocations(CollocationSpec(
            attribute: "word", leftWindow: -1, rightWindow: 0,
            minFrequency: 1, minCollocateFrequency: 1, maxItems: 2))
        XCTAssertEqual(items.count, 2)
    }

    func testCollocationsThrowsForUnknownAttribute() async throws {
        let live = try await makeLiveConcordance()
        do {
            _ = try await live.collocations(CollocationSpec(attribute: "not_a_real_attr"))
            XCTFail("expected an error for an unknown attribute")
        } catch {
            // Expected - Manatee's own PosAttr lookup failure surfaces as a
            // thrown ManateeError, same as every other shim call.
        }
    }
}
