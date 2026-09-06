import XCTest

@testable import ManateeKit

final class CorpusImporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CorpusImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        unsetenv("CORPORA_COMPILED_CORPORA_DIRECTORY")
    }

    private func writeVerticalFile(_ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent("test.vert")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSniffSchemaDetectsAttributesAndStructures() async throws {
        let vert = try writeVerticalFile("""
            <doc id="1" author="twain">
            <s>
            the\tthe\tDT
            fox\tfox\tNN
            </s>
            </doc>
            """)
        let schema = try await CorpusImporter.sniffSchema(verticalFile: vert)
        XCTAssertEqual(schema.attributes, ["attr2", "attr3"])
        XCTAssertEqual(schema.structures.map(\.name), ["doc", "s"])
        XCTAssertEqual(schema.structures.first { $0.name == "doc" }?.attributes, ["author", "id"])
        XCTAssertEqual(schema.structures.first { $0.name == "s" }?.attributes, [])
    }

    func testCountLinesMatchesActualLineCount() async throws {
        // Trailing newline is deliberate - countLines counts raw `\n` bytes
        // (fast; no UTF-8 line decoding), matching a normally-terminated
        // real vertical file, unlike Swift's triple-quote literal syntax
        // (which doesn't include a newline after the last line).
        let vert = try writeVerticalFile("""
            <doc id="1">
            <s>
            the\tthe\tDT
            fox\tfox\tNN
            </s>
            </doc>

            """)
        let count = try await CorpusImporter.countLines(verticalFile: vert)
        XCTAssertEqual(count, 6)
    }

    func testCountLinesReusesCachedResultForUnchangedFileThenInvalidatesOnChange() async throws {
        let vert = try writeVerticalFile("line one\nline two\n")
        let first = try await CorpusImporter.countLines(verticalFile: vert)
        XCTAssertEqual(first, 2)

        // Same file, unchanged - should still be 2 (from cache or a fresh
        // count, this doesn't distinguish which, but proves the cache isn't
        // returning something stale/wrong for the unchanged-file case).
        let second = try await CorpusImporter.countLines(verticalFile: vert)
        XCTAssertEqual(second, 2)

        // Actually changing the file's content (and therefore its size,
        // which the cache keys on alongside modification date) must not
        // return the old cached count.
        try "line one\nline two\nline three\n".write(to: vert, atomically: true, encoding: .utf8)
        let third = try await CorpusImporter.countLines(verticalFile: vert)
        XCTAssertEqual(third, 3)
    }

    func testSniffSchemaThrowsForFileWithNoDataLines() async throws {
        let vert = try writeVerticalFile("<doc>\n</doc>\n")
        do {
            _ = try await CorpusImporter.sniffSchema(verticalFile: vert)
            XCTFail("expected an error for a file with no token lines")
        } catch {
            // Expected.
        }
    }

    func testImportCorpusCompilesAndIsQueryable() async throws {
        let compiledDir = tempDir.appendingPathComponent("compiled")
        setenv("CORPORA_COMPILED_CORPORA_DIRECTORY", compiledDir.path, 1)

        let vert = try writeVerticalFile("""
            <doc id="1">
            <s>
            the\tthe\tDT
            fox\tfox\tNN
            </s>
            </doc>
            """)

        try await CorpusImporter.importCorpus(
            name: "importtest", verticalFile: vert,
            attributes: ["lemma", "tag"],
            structures: [(name: "doc", attributes: ["id"]), (name: "s", attributes: [])],
            onProgress: { _ in })

        // mtc_corpus_open reads MANATEE_REGISTRY via getenv() fresh on every
        // call (see TestCorpusFixture) - point it at the directory the
        // corpus was just compiled into so it can actually be opened.
        setenv("MANATEE_REGISTRY", compiledDir.path, 1)
        let corpus = try await Corpus(name: "importtest")
        let lines = try await corpus.query(#"[word="fox"]"#)
        XCTAssertEqual(lines.count, 1)
    }
}
