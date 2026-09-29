import Cocoa
import ManateeKit
import Testing
@testable import Korpora

/// Cancelling a search (docs/project-plan.md, "Cancel a running query") as
/// the document sees it, against a real tiny corpus compiled for each test
/// (through the import tool the app bundles; the dev checkout's `encodevert`
/// here). Serialized: it points the process environment at a temporary
/// registry.
@MainActor @Suite(.serialized) final class ConcordanceDocumentCancelTests {
    private let root: URL
    private let saved: [(String, String?)]
    private let defaults = UserDefaults(suiteName: "ConcordanceDocumentCancelTests-\(UUID().uuidString)")!
    private static let corpus = "korporacancel"

    init() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ConcordanceDocumentCancelTests-\(UUID().uuidString)")
        let compiled = root.appendingPathComponent("compiled")
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        let keys = ["KORPORA_COMPILED_CORPORA_DIRECTORY", "MANATEE_REGISTRY"]
        saved = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("KORPORA_COMPILED_CORPORA_DIRECTORY", compiled.path, 1)
        setenv("MANATEE_REGISTRY", compiled.path, 1)

        // brown fox, lazy dog, curious cat, sleepy cat: 5 JJ, 4 NN.
        let vertical = root.appendingPathComponent("test.vert")
        try """
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
            """.write(to: vertical, atomically: true, encoding: .utf8)
        try await CorpusImporter.importCorpus(
            name: Self.corpus, verticalFile: vertical, attributes: ["lemma", "tag"],
            structures: [(name: "doc", attributes: ["id"]), (name: "s", attributes: [])],
            onProgress: { _ in })
    }

    deinit {
        for (key, value) in saved {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func document() -> ConcordanceDocument {
        let document = ConcordanceDocument()
        document.corpusName = Self.corpus
        document.historyDefaults = defaults
        return document
    }

    private func waitUntilDone(_ document: ConcordanceDocument) async {
        for _ in 0..<2500 where document.isSearching {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func aSearchThatIsNotCancelledCompletes() async {
        let document = document()
        document.runQuery(#"[tag="NN"]"#)
        #expect(document.isSearching && document.status == "Searching…")
        await waitUntilDone(document)
        #expect(!document.isSearching)
        #expect(document.status.hasPrefix("4 hits"), "\(document.status)")
        #expect(document.rows.count == 4)
    }

    /// Cancelled before the search gets going: it stops, shows no results and
    /// says so; the query stays, so it can be run again.
    @Test func aCancelledSearchSaysSoAndKeepsTheQuery() async {
        let document = document()
        document.runQuery(#"[tag="NN"]"#)
        #expect(document.isSearching)
        document.cancelSearch()
        await waitUntilDone(document)
        #expect(!document.isSearching)
        #expect(document.status == "Search cancelled.")
        #expect(document.rows.isEmpty)
        #expect(document.initialQuery == #"[tag="NN"]"#)

        // Searching again works.
        document.runQuery(document.initialQuery)
        await waitUntilDone(document)
        #expect(document.status.hasPrefix("4 hits"), "\(document.status)")
    }

    /// A new search replaces one that is still running, and the replaced one
    /// leaves no trace: not its results, and not a "cancelled" message.
    @Test func aNewerSearchReplacesARunningOne() async {
        let document = document()
        document.runQuery(#"[tag="JJ"]"#)
        document.runQuery(#"[tag="NN"]"#)
        await waitUntilDone(document)
        #expect(document.status.hasPrefix("4 hits"), "\(document.status)")
        #expect(document.rows.count == 4)
        #expect(document.initialQuery == #"[tag="NN"]"#)
    }

    @Test func cancellingWhenNothingIsRunningDoesNothing() async {
        let document = document()
        document.cancelSearch()
        #expect(!document.isSearching && document.status.isEmpty)
        document.runQuery(#"[tag="NN"]"#)
        await waitUntilDone(document)
        document.cancelSearch()
        #expect(document.status.hasPrefix("4 hits"), "\(document.status)")
        #expect(document.rows.count == 4)
    }

    /// The window's hint and the menu item follow the document.
    @Test func theWindowShowsTheHintWhileSearching() async throws {
        let document = document()
        let controller = ConcordanceViewController(document: document)
        _ = controller.view
        #expect(controller.cancelHintLabel.isHidden)
        #expect(controller.cancelHintLabel.stringValue == "Press \u{2318}. to cancel")
        let item = NSMenuItem(title: "Cancel Search", action: #selector(ConcordanceViewController.cancelSearch(_:)), keyEquivalent: ".")
        #expect(!controller.validateMenuItem(item))

        document.runQuery(#"[tag="NN"]"#)
        #expect(!controller.cancelHintLabel.isHidden)
        #expect(controller.validateMenuItem(item))
        await waitUntilDone(document)
        #expect(controller.cancelHintLabel.isHidden)
        #expect(!controller.validateMenuItem(item))
    }
}
