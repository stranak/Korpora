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
        let info = try await corpus.info()

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

    /// Phase 6.6 (Extended Context): a plain-position-range fetch, no live
    /// query/concordance needed. "the quick brown fox jumps" is the
    /// fixture's first sentence, positions 0-4.
    func testPositionalAttributeRangeReturnsSpaceJoinedTokens() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let words = try await corpus.positionalAttributeRange(from: 0, to: 5, attribute: "word")
        XCTAssertEqual(words, "the quick brown fox jumps")

        let lemmas = try await corpus.positionalAttributeRange(from: 3, to: 5, attribute: "lemma")
        XCTAssertEqual(lemmas, "fox jump")
    }

    func testPositionalAttributeRangeClampsToCorpusBounds() async throws {
        // The fixture is 17 tokens (0-16) - a request running off either
        // end (as "position ± N" naturally does for a hit near the start
        // or end of the corpus) must clamp, not throw or read garbage.
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let clampedStart = try await corpus.positionalAttributeRange(from: -10, to: 3, attribute: "word")
        XCTAssertEqual(clampedStart, "the quick brown")

        let clampedEnd = try await corpus.positionalAttributeRange(from: 15, to: 100, attribute: "word")
        XCTAssertEqual(clampedEnd, "cat yawns")
    }

    /// Regression (2026-09-08): a registry `PATH` is an absolute path, so it
    /// can stop resolving without the registry file itself changing - a moved
    /// directory, an unmounted volume, a deleted `.data` sibling. The corpus
    /// still *opens* (opening only parses the registry file), and the failure
    /// surfaces on the first call that touches compiled data.
    ///
    /// That call was `mtc_corpus_size`, and it had no `try`/`catch`, so
    /// Manatee's throw unwound across the `extern "C"` boundary and
    /// `abort()`ed the process - which is how a stale dev-corpus path took
    /// down the whole app from the New Concordance picker, and took the test
    /// host with it (the suite reported "not run" rather than failing). It
    /// must be a catchable Swift error.
    func testSizeThrowsWhenRegistryPathDoesNotResolve() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ManateeKitBrokenPath-\(UUID().uuidString)")
        let registryDir = tempDir.appendingPathComponent("registry")
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let registryContent = """
        NAME "Broken Path"
        INFO "registry whose PATH does not resolve"
        PATH "\(tempDir.appendingPathComponent("gone").path)"
        LANGUAGE "en"
        ENCODING "utf-8"

        ATTRIBUTE word
        """
        try registryContent.write(
            to: registryDir.appendingPathComponent("brokenpath"), atomically: true, encoding: .utf8)

        // The fixture set MANATEE_REGISTRY process-wide in setUp; point it at
        // this registry for the duration and put it back afterward, so test
        // order can't matter.
        let previous = ProcessInfo.processInfo.environment["MANATEE_REGISTRY"]
        setenv("MANATEE_REGISTRY", registryDir.path, 1)
        defer {
            if let previous {
                setenv("MANATEE_REGISTRY", previous, 1)
            } else {
                unsetenv("MANATEE_REGISTRY")
            }
        }

        let corpus = try await Corpus(name: "brokenpath")
        do {
            _ = try await corpus.size
            XCTFail("expected size to throw when the registry PATH doesn't resolve")
        } catch {
            // Expected.
        }

        // info() reads sizeTokens from size, so it has to propagate rather
        // than reporting a bogus size for an unreadable corpus.
        do {
            _ = try await corpus.info()
            XCTFail("expected info() to throw when the registry PATH doesn't resolve")
        } catch {
            // Expected.
        }
    }

    func testPositionalAttributeRangeThrowsForUnknownAttribute() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        do {
            _ = try await corpus.positionalAttributeRange(from: 0, to: 1, attribute: "notreal")
            XCTFail("expected an error for an unknown positional attribute")
        } catch {
            // Expected.
        }
    }
}
