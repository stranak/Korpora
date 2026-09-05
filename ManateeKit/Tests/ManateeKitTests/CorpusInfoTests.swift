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
}
