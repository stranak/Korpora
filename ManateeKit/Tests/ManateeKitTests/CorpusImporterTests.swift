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
        unsetenv("KORPORA_COMPILED_CORPORA_DIRECTORY")
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

    func testImportCorpusWipesStaleFilesFromAPreviousAttempt() async throws {
        let compiledDir = tempDir.appendingPathComponent("compiled")
        setenv("KORPORA_COMPILED_CORPORA_DIRECTORY", compiledDir.path, 1)

        let vert = try writeVerticalFile("""
            <doc id="1">
            <s>
            the\tthe\tDT
            fox\tfox\tNN
            </s>
            </doc>
            """)

        // Simulates a leftover file from an earlier, different-schema
        // attempt at the same corpus name - encodevert writes *into*
        // whatever's already in the data directory rather than starting
        // clean, so without importCorpus wiping it first, this would still
        // be sitting there mixed in with the new compile's own files.
        let dataDirectory = CompiledCorpusStore.dataDirectory(for: "stale")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let staleFile = dataDirectory.appendingPathComponent("leftover-from-old-attempt")
        try Data([0]).write(to: staleFile)

        try await CorpusImporter.importCorpus(
            name: "stale", verticalFile: vert,
            attributes: ["lemma", "tag"],
            structures: [(name: "doc", attributes: ["id"]), (name: "s", attributes: [])],
            onProgress: { _ in })

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleFile.path),
            "importCorpus should wipe the data directory before compiling, not leave old files mixed in")
    }

    func testMakeRegistryTextDoesNotDuplicateAttributeWordWhenCallerIncludesIt() {
        // A user describing their vertical file's own columns may
        // reasonably include "word" as one of them - the registry must
        // still only declare ATTRIBUTE word once. Two ATTRIBUTE word lines
        // previously crashed encodevert against a real 162M-line corpus
        // (two write_attr objects racing to rename the same temp file).
        let registryText = CorpusImporter.makeRegistryText(
            name: "test", dataDirectory: tempDir, verticalFile: tempDir,
            attributes: ["word", "lemma", "tag"], structures: [])
        let occurrences = registryText.components(separatedBy: "ATTRIBUTE word").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testImportCorpusRefusesToCompileWhenDeclaredAttributesDontMatchFileColumns() async throws {
        let compiledDir = tempDir.appendingPathComponent("compiled")
        setenv("KORPORA_COMPILED_CORPORA_DIRECTORY", compiledDir.path, 1)

        // Three tab-separated columns per line (word, lemma, tag), but the
        // caller only declares "lemma" - i.e. exactly the kind of mismatch
        // a user mistyping/miscounting the Positional Attributes field
        // would produce. Must be caught before encodevert ever runs, not
        // discovered later via a crash or silently wrong query results.
        let vert = try writeVerticalFile("""
            <doc id="1">
            the\tthe\tDT
            fox\tfox\tNN
            </doc>
            """)

        do {
            try await CorpusImporter.importCorpus(
                name: "mismatched", verticalFile: vert,
                attributes: ["lemma"],
                structures: [(name: "doc", attributes: ["id"])],
                onProgress: { _ in })
            XCTFail("expected an attributeCountMismatch error")
        } catch CorpusImportError.attributeCountMismatch(let declared, let actualColumns) {
            XCTAssertEqual(declared, 2)
            XCTAssertEqual(actualColumns, 3)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: CompiledCorpusStore.registryPath(for: "mismatched").path),
            "a rejected import should never write a registry file")
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
        setenv("KORPORA_COMPILED_CORPORA_DIRECTORY", compiledDir.path, 1)

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
