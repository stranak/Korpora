import XCTest

@testable import ManateeKit

/// Phase 6.7: attribute *value* enumeration (the lexicon), as opposed to
/// `CorpusInfoTests`' attribute *name* introspection. Shared foundation for
/// CQL value autocomplete (6.8) and Text-Types subcorpus building (6.9).
final class AttributeValuesTests: XCTestCase {
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

    /// `tag` is the fixture's smallest positional lexicon - DT/JJ/NN/VBZ
    /// across all 17 tokens (see `TestCorpusFixture.vertContent`).
    func testValuesOfASmallPositionalAttribute() async throws {
        let corpus = try await openFixture()
        let tags = try await corpus.attributeValues(attribute: "tag")
        XCTAssertEqual(tags.sorted(), ["DT", "JJ", "NN", "VBZ"])
    }

    /// Distinct values, not token count: 17 tokens, 4 distinct tags. And it
    /// must agree with what `attributeValues` actually returns, which is
    /// the contract the UI relies on to choose list-vs-search.
    func testValueCountIsDistinctValuesNotTokens() async throws {
        let corpus = try await openFixture()
        let count = try await corpus.attributeValueCount(attribute: "tag")
        let values = try await corpus.attributeValues(attribute: "tag")
        XCTAssertEqual(count, 4)
        XCTAssertEqual(count, values.count)
    }

    /// The payoff of routing through `Corpus::get_attr`: a structural
    /// attribute needs no separate code path, and comes back already
    /// deduplicated - `doc.id` is "1" and "2", one entry each, even though
    /// the two <doc>s span 17 token positions between them.
    func testStructuralAttributeValuesAreDeduplicated() async throws {
        let corpus = try await openFixture()
        let ids = try await corpus.attributeValues(attribute: "doc.id")
        XCTAssertEqual(ids.sorted(), ["1", "2"])
        let count = try await corpus.attributeValueCount(attribute: "doc.id")
        XCTAssertEqual(count, 2)
    }

    /// `word` and `lemma` differ where the fixture inflects (jumps/jump,
    /// sleeps/sleep, purrs/purr, yawns/yawn) - a check that these read the
    /// requested attribute's own lexicon rather than defaulting to `word`.
    func testDifferentAttributesReturnTheirOwnLexicons() async throws {
        let corpus = try await openFixture()
        let words = try await corpus.attributeValues(attribute: "word")
        let lemmas = try await corpus.attributeValues(attribute: "lemma")
        XCTAssertTrue(words.contains("jumps"))
        XCTAssertFalse(words.contains("jump"))
        XCTAssertTrue(lemmas.contains("jump"))
        XCTAssertFalse(lemmas.contains("jumps"))
    }

    func testMatchingFiltersToThePattern() async throws {
        let corpus = try await openFixture()
        let vTags = try await corpus.attributeValues(attribute: "tag", matching: "V.*")
        XCTAssertEqual(vTags, ["VBZ"])
    }

    /// Manatee matches the pattern against the *whole* value, so a bare
    /// "N" does not match "NN" - the reason the API's doc comment tells
    /// callers a prefix search needs a trailing ".*".
    func testMatchingIsWholeValueNotSubstring() async throws {
        let corpus = try await openFixture()
        let bare = try await corpus.attributeValues(attribute: "tag", matching: "N")
        XCTAssertEqual(bare, [])
        let anchored = try await corpus.attributeValues(attribute: "tag", matching: "N.*")
        XCTAssertEqual(anchored, ["NN"])
    }

    func testMatchingHonorsIgnoreCase() async throws {
        let corpus = try await openFixture()
        let insensitive = try await corpus.attributeValues(
            attribute: "tag", matching: "vbz", ignoreCase: true)
        XCTAssertEqual(insensitive, ["VBZ"])
        let sensitive = try await corpus.attributeValues(
            attribute: "tag", matching: "vbz", ignoreCase: false)
        XCTAssertEqual(sensitive, [])
    }

    /// The limit is what makes this usable as a search-as-you-type box over
    /// a high-cardinality attribute - it stops the lexicon scan rather than
    /// truncating a full dump.
    func testLimitCapsTheNumberOfMatches() async throws {
        let corpus = try await openFixture()
        let all = try await corpus.attributeValues(attribute: "tag", matching: ".*")
        XCTAssertEqual(all.count, 4)

        let capped = try await corpus.attributeValues(attribute: "tag", matching: ".*", limit: 2)
        XCTAssertEqual(capped.count, 2)
        // A cap takes a prefix of the same order, not an arbitrary subset.
        XCTAssertEqual(capped, Array(all.prefix(2)))
    }

    func testZeroLimitMeansNoLimit() async throws {
        let corpus = try await openFixture()
        let capped = try await corpus.attributeValues(attribute: "tag", matching: ".*", limit: 0)
        XCTAssertEqual(capped.count, 4)
    }

    /// A limit larger than the number of matches is not an error and does
    /// not pad.
    func testLimitLargerThanTheResultSetReturnsEverything() async throws {
        let corpus = try await openFixture()
        let capped = try await corpus.attributeValues(attribute: "tag", matching: ".*", limit: 100)
        XCTAssertEqual(capped.count, 4)
    }

    /// A pattern matching nothing is an empty list, not an error - a
    /// search box mid-typing hits this constantly.
    func testPatternMatchingNothingReturnsEmpty() async throws {
        let corpus = try await openFixture()
        let none = try await corpus.attributeValues(attribute: "tag", matching: "ZZZ.*")
        XCTAssertTrue(none.isEmpty)
    }

    func testUnknownAttributeThrows() async throws {
        let corpus = try await openFixture()
        do {
            _ = try await corpus.attributeValues(attribute: "notreal")
            XCTFail("expected an error for an unknown attribute")
        } catch {
            // Expected.
        }
        do {
            _ = try await corpus.attributeValueCount(attribute: "notreal")
            XCTFail("expected an error for an unknown attribute")
        } catch {
            // Expected.
        }
        do {
            _ = try await corpus.attributeValues(attribute: "notreal", matching: ".*")
            XCTFail("expected an error for an unknown attribute")
        } catch {
            // Expected.
        }
    }
}
