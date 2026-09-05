import XCTest

@testable import ManateeKit

final class ManateeKitTests: XCTestCase {
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

    private var corpusName: String { Self.fixture.corpusName }

    func testCorpusSizeMatchesTokenCount() async throws {
        let corpus = try await Corpus(name: corpusName)
        let size = await corpus.size
        XCTAssertEqual(size, 17)  // 5 + 4 + 4 + 4 tokens across the 4 sentences
    }

    func testAdjectiveNounQueryFindsBothMatches() async throws {
        let corpus = try await Corpus(name: corpusName)
        // Small explicit context: the KWIC API caps context at the corpus's
        // edges anyway, and a leading space it puts on `kwic`/`right` (from an
        // empty markup token in Manatee's own output) isn't what's under test.
        let lines = try await corpus.query(
            #"[tag="JJ"][tag="NN"]"#, leftContext: "-1", rightContext: "1")

        XCTAssertEqual(
            lines.map { $0.kwic.trimmingCharacters(in: .whitespaces) },
            ["brown fox", "lazy dog", "curious cat", "sleepy cat"])
        XCTAssertEqual(
            lines.map { $0.left.trimmingCharacters(in: .whitespaces) }, ["quick", "the", "a", "the"])
        XCTAssertEqual(
            lines.map { $0.right.trimmingCharacters(in: .whitespaces) }, ["jumps", "sleeps", "purrs", "yawns"])
    }

    func testQueryWithNoMatchesReturnsEmpty() async throws {
        let corpus = try await Corpus(name: corpusName)
        let lines = try await corpus.query(#"[tag="VB"]"#)
        XCTAssertTrue(lines.isEmpty)
    }

    func testAvailableCorpusNamesListsTheFixtureCorpus() {
        XCTAssertEqual(CorpusRegistry.availableCorpusNames(), [corpusName])
    }

    func testOpeningUnregisteredCorpusThrows() async {
        do {
            _ = try await Corpus(name: "no-such-corpus-in-registry")
            XCTFail("expected an error opening a corpus that isn't in the registry")
        } catch is ManateeError {
            // expected
        } catch {
            XCTFail("expected a ManateeError, got \(error)")
        }
    }
}
