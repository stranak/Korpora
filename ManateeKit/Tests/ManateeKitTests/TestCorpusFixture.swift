import Foundation

/// Builds a small hand-written corpus (4 sentences, 17 tokens) - grown from
/// the 2-sentence corpus `scripts/setup-dev-machine.sh`'s smoke test still
/// uses, so sort/shuffle/sample/filter/line-group operations have more than
/// one or two lines of non-trivial, repeated-tag data to operate on.
struct TestCorpusFixture {
    // Deliberately not "testcorp" (2026-09-06): that's also the real dev
    // corpus's name in the Korpora app, and SubcorpusStore keys subcorpus
    // storage by corpus name alone in a permanent, shared
    // ~/Library/Application Support/Korpora/Subcorpora/<name>/ directory -
    // SubcorpusTests' teardown deleting that directory for "testcorp" once
    // deleted a real subcorpus created via manual UI testing. A name unique
    // to this fixture can never collide with a real corpus again.
    let corpusName = "mkittest"
    private let tempDir: URL

    static func build() throws -> TestCorpusFixture {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ManateeKitTests-\(UUID().uuidString)")
        let vertDir = tempDir.appendingPathComponent("vert")
        let registryDir = tempDir.appendingPathComponent("registry")
        let dataDir = tempDir.appendingPathComponent("data")
        for dir in [vertDir, registryDir, dataDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let vertPath = vertDir.appendingPathComponent("test.vert")
        try vertContent.write(to: vertPath, atomically: true, encoding: .utf8)

        let registryContent = """
        NAME "Test Corpus"
        INFO "tiny smoke-test corpus"
        PATH "\(dataDir.path)"
        VERTICAL "\(vertPath.path)"
        LANGUAGE "en"
        ENCODING "utf-8"

        ATTRIBUTE word
        ATTRIBUTE lemma {
        }
        ATTRIBUTE tag {
        }
        STRUCTURE doc {
            ATTRIBUTE id
        }
        STRUCTURE s {
        }
        """
        try registryContent.write(
            to: registryDir.appendingPathComponent("mkittest"), atomically: true, encoding: .utf8)

        // mtc_corpus_open reads MANATEE_REGISTRY via getenv() on every call (not
        // cached), so setting it here for this process is enough for the whole
        // test run - no need to plumb it through per-call.
        setenv("MANATEE_REGISTRY", registryDir.path, 1)

        let encodevert = manateeRoot().appendingPathComponent("src/encodevert")
        guard FileManager.default.isExecutableFile(atPath: encodevert.path) else {
            throw FixtureError(
                "encodevert not found at \(encodevert.path) - build manatee-open first "
                    + "(see scripts/setup-dev-machine.sh)")
        }

        let process = Process()
        process.executableURL = encodevert
        process.arguments = ["-v", "-c", "mkittest"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw FixtureError("encodevert exited \(process.terminationStatus): \(output)")
        }

        return TestCorpusFixture(tempDir: tempDir)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Package.swift resolves manatee-open the same way, relative to this
    // package's own root rather than any hardcoded machine path.
    private static func manateeRoot() -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ManateeKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ManateeKit (package root)
        return packageRoot.deletingLastPathComponent().appendingPathComponent("manatee-open")
    }

    // Two <doc>s (not one) so subcorpus tests have something meaningful to
    // restrict to - see SubcorpusTests.
    private static let vertContent = """
        <doc id="1">
        <s>
        the\tthe\tDT
        quick\tquick\tJJ
        brown\tbrown\tJJ
        fox\tfox\tNN
        jumps\tjump\tVBZ
        </s>
        <s>
        the\tthe\tDT
        lazy\tlazy\tJJ
        dog\tdog\tNN
        sleeps\tsleep\tVBZ
        </s>
        </doc>
        <doc id="2">
        <s>
        a\ta\tDT
        curious\tcurious\tJJ
        cat\tcat\tNN
        purrs\tpurr\tVBZ
        </s>
        <s>
        the\tthe\tDT
        sleepy\tsleepy\tJJ
        cat\tcat\tNN
        yawns\tyawn\tVBZ
        </s>
        </doc>
        """
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
