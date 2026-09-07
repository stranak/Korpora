import XCTest

@testable import ManateeKit

final class CorpusInfoTests: XCTestCase {
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

    func testInfoListsPositionalAttributesAndStructures() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let info = await corpus.info()

        XCTAssertEqual(info.name, Self.fixture.corpusName)
        XCTAssertEqual(info.sizeTokens, 17)
        XCTAssertEqual(Set(info.attributes), ["word", "lemma", "tag"])

        let structNames = Set(info.structures.map(\.name))
        XCTAssertEqual(structNames, ["doc", "s"])
        let doc = info.structures.first { $0.name == "doc" }
        XCTAssertEqual(doc?.attributes, ["id"])
        let sentence = info.structures.first { $0.name == "s" }
        XCTAssertEqual(sentence?.attributes, [])
    }

    func testStructuralAttributeValueMatchesTheEnclosingDocument() async throws {
        // "fox" only appears in <doc id="1">, "cat" only in <doc id="2">
        // (see TestCorpusFixture.vertContent) - a real per-match lookup, not
        // just registry metadata like testInfoListsPositionalAttributesAndStructures.
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let foxLines = try await corpus.query(#"[word="fox"]"#)
        XCTAssertEqual(foxLines.count, 1)
        let foxDocID = try await corpus.structuralAttributeValue(
            at: foxLines[0].position, attribute: "doc.id")
        XCTAssertEqual(foxDocID, "1")

        let catLines = try await corpus.query(#"[word="cat"]"#)
        XCTAssertEqual(catLines.count, 2)
        for line in catLines {
            let docID = try await corpus.structuralAttributeValue(at: line.position, attribute: "doc.id")
            XCTAssertEqual(docID, "2")
        }
    }

    func testStructuralAttributeValueThrowsForUnknownAttribute() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let lines = try await corpus.query(#"[word="fox"]"#)
        do {
            _ = try await corpus.structuralAttributeValue(at: lines[0].position, attribute: "doc.notreal")
            XCTFail("expected an error for an unknown structural attribute")
        } catch {
            // Expected.
        }
    }
}
