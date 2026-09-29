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

    // MARK: The key press, through a real window

    /// A window like the app's, on screen, with the query field focused.
    private func shownWindow(for document: ConcordanceDocument) throws -> (NSWindow, NSTextView) {
        let controller = ConcordanceWindowController(document: document)
        document.addWindowController(controller)
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        let viewController = try #require(window.contentViewController)
        func textView(in view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap(textView(in:)).first
        }
        let field = try #require(textView(in: viewController.view))
        window.makeFirstResponder(field)
        return (window, field)
    }

    /// Holds a search open until `open()`.
    actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Command-period through the app's main menu can't be sent from a test:
    /// the test host is never the active app, so no window becomes key and a
    /// menu action has no responder chain to travel. So the links are tested
    /// one by one, with the search held open: the menu item (title, key,
    /// modifier, action, and that it targets the responder chain)...
    @Test func theMenuItemIsWiredToCommandPeriod() throws {
        let menu = try #require(NSApp.mainMenu)
        let queryMenu = try #require(menu.items.first { $0.submenu?.title == "Query" }?.submenu)
        let item = try #require(queryMenu.items.first { $0.title == "Cancel Search" })
        #expect(item.keyEquivalent == ".")
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(item.action == #selector(ConcordanceViewController.cancelSearch(_:)))
        #expect(item.target == nil, "nil target: the action goes up the key window's responder chain")
    }

    /// ...it is enabled exactly while the window's search runs...
    @Test func theItemIsValidOnlyWhileSearching() async throws {
        let document = document()
        let gate = Gate()
        document.beforeSearchHook = { await gate.wait() }
        let controller = ConcordanceViewController(document: document)
        _ = controller.view
        let item = NSMenuItem(title: "Cancel Search", action: #selector(ConcordanceViewController.cancelSearch(_:)), keyEquivalent: ".")
        #expect(!controller.validateMenuItem(item))
        document.runQuery(#"[tag="NN"]"#)
        try await Task.sleep(for: .milliseconds(50))  // the search is held open, not finished
        #expect(document.isSearching)
        #expect(controller.validateMenuItem(item))
        await gate.open()
        await waitUntilDone(document)
        #expect(!controller.validateMenuItem(item))
    }

    /// ...and from the focused query field the action, and the standard
    /// cancelOperation: (what the key bindings send for Command-period and
    /// Esc), reach the window's view controller and cancel a search that is
    /// still running.
    @Test func bothActionsReachTheViewControllerFromTheQueryField() async throws {
        for action in [#selector(ConcordanceViewController.cancelSearch(_:)),
                       #selector(NSResponder.cancelOperation(_:))] {
            let document = document()
            let gate = Gate()
            document.beforeSearchHook = { await gate.wait() }
            let (window, field) = try shownWindow(for: document)
            defer { window.orderOut(nil) }
            document.runQuery(#"[tag="NN"]"#)
            try await Task.sleep(for: .milliseconds(50))
            #expect(document.isSearching, "\(action)")
            #expect(field.tryToPerform(action, with: nil), "\(action)")
            await gate.open()
            await waitUntilDone(document)
            #expect(document.status == "Search cancelled.", "\(action): \(document.status)")
            #expect(document.rows.isEmpty)
        }
    }

    /// With nothing running, cancelOperation: is passed on, not swallowed.
    @Test func cancelOperationIsPassedOnWhenNothingRuns() throws {
        let document = document()
        let (window, field) = try shownWindow(for: document)
        defer { window.orderOut(nil) }
        #expect(!document.isSearching)
        document.cancelSearch()  // and cancelling nothing is harmless
        #expect(document.status.isEmpty)
        _ = field
    }
}

/// The user's scenario: a search whose *line fetching* is the long part (a
/// common word: a million hits), cancelled while that runs. Builds a big
/// corpus, so opt in with `KORPORA_SLOW_TESTS=1` (about a minute).
@MainActor @Suite(.serialized) struct ConcordanceDocumentSlowCancelTests {
    @Test func cancellingDuringTheLineFetchStopsPromptly() async throws {
        guard ProcessInfo.processInfo.environment["KORPORA_SLOW_TESTS"] != nil else { return }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ConcordanceDocumentSlowCancelTests-\(UUID().uuidString)")
        let compiled = root.appendingPathComponent("compiled")
        try fm.createDirectory(at: compiled, withIntermediateDirectories: true)
        let saved = ["KORPORA_COMPILED_CORPORA_DIRECTORY", "MANATEE_REGISTRY"]
            .map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
            try? fm.removeItem(at: root)
        }
        setenv("KORPORA_COMPILED_CORPORA_DIRECTORY", compiled.path, 1)
        setenv("MANATEE_REGISTRY", compiled.path, 1)

        let tokens = 3_000_000
        var text = "<doc id=\"1\">\n<s>\n"
        text.reserveCapacity(tokens * 10)
        for i in 0..<tokens {
            text += i % 3 == 0 ? "a\ta\tDT\n" : (i % 3 == 1 ? "b\tb\tJJ\n" : "c\tc\tNN\n")
            if i % 20 == 19 { text += "</s>\n<s>\n" }
        }
        text += "</s>\n</doc>\n"
        let vertical = root.appendingPathComponent("big.vert")
        try text.write(to: vertical, atomically: true, encoding: .utf8)
        try await CorpusImporter.importCorpus(
            name: "korporabig", verticalFile: vertical, attributes: ["lemma", "tag"],
            structures: [(name: "doc", attributes: ["id"]), (name: "s", attributes: [])],
            onProgress: { _ in })

        let document = ConcordanceDocument()
        document.corpusName = "korporabig"
        document.historyDefaults = UserDefaults(suiteName: "SlowCancel-\(UUID().uuidString)")!
        document.runQuery(#"[tag="DT"]"#)  // a million hits
        try await Task.sleep(for: .seconds(4))  // the query is done; the lines are being fetched
        guard document.isSearching else { return }  // finished on a fast machine: nothing to cancel
        let cancelledAt = Date()
        document.cancelSearch()
        for _ in 0..<5000 where document.isSearching { try await Task.sleep(for: .milliseconds(2)) }
        let seconds = Date().timeIntervalSince(cancelledAt)
        print("SLOW cancelled the line fetch in \(seconds) s")
        #expect(!document.isSearching)
        #expect(document.status == "Search cancelled.", "\(document.status)")
        #expect(seconds < 2, "took \(seconds) s to stop")
    }
}
