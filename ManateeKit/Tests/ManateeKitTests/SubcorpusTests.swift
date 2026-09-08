import XCTest

@testable import ManateeKit

final class SubcorpusTests: XCTestCase {
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
        // Subcorpus files are written under SubcorpusStore.baseDirectory
        // (Application Support), independent of the fixture's temp dir -
        // clean those up too so repeated test runs don't accumulate them.
        try? FileManager.default.removeItem(at: SubcorpusStore.directory(for: fixture.corpusName))
        fixture = nil
        super.tearDown()
    }

    func testCreateAndQueryWithinSubcorpus() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)

        // "id" not "doc.id" - create_subcorpus evaluates the query with the
        // structure itself as the corpus, where its own attributes are
        // unprefixed (see corp/subcorp.cc's create_subcorpus).
        let path = try await corpus.createSubcorpus(named: "doc1", structure: "doc", query: #"id="1""#)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let subcorpus = try await corpus.openSubcorpus(atPath: path)
        let size = try await subcorpus.size
        XCTAssertEqual(size, 9)  // doc 1 only: "the quick brown fox jumps" + "the lazy dog sleeps"

        let lines = try await subcorpus.query(#"[tag="JJ"][tag="NN"]"#, leftContext: "-1", rightContext: "1")
        XCTAssertEqual(
            lines.map { $0.kwic.trimmingCharacters(in: .whitespaces) },
            ["brown fox", "lazy dog"])
    }

    func testSubcorpusExcludesOtherDocuments() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let path = try await corpus.createSubcorpus(named: "doc2", structure: "doc", query: #"id="2""#)
        let subcorpus = try await corpus.openSubcorpus(atPath: path)

        let lines = try await subcorpus.query(#"[tag="JJ"][tag="NN"]"#, leftContext: "-1", rightContext: "1")
        XCTAssertEqual(
            lines.map { $0.kwic.trimmingCharacters(in: .whitespaces) },
            ["curious cat", "sleepy cat"])
    }

    func testAvailableSubcorporaListsCreatedOnes() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        XCTAssertEqual(SubcorpusStore.availableSubcorpora(for: Self.fixture.corpusName), [])

        _ = try await corpus.createSubcorpus(named: "doc1", structure: "doc", query: #"id="1""#)
        _ = try await corpus.createSubcorpus(named: "doc2", structure: "doc", query: #"id="2""#)

        XCTAssertEqual(SubcorpusStore.availableSubcorpora(for: Self.fixture.corpusName), ["doc1", "doc2"])
    }
}
