import Foundation
import ManateeKit
import Testing
@testable import Korpora

/// The app side of the unified corpus list (docs/project-plan.md, "Corpus
/// Settings UX"): "Keep in Memory" flags stored per corpus name, and the
/// one-time carry-over of the retired registry-directories setting and the
/// old per-corpus flags. Serialized: the migration works through process
/// environment variables.
@Suite(.serialized) struct CorpusListSettingsTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CorpusListSettingsTests-\(UUID().uuidString)")!
    }

    @Test func keepResidentFlagsAreStoredPerName() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.keepResidentCorpora.isEmpty)
        settings.setKeepResident(true, for: "syn2025")
        settings.setKeepResident(true, for: "ud")
        settings.setKeepResident(false, for: "ud")
        #expect(settings.isKeepResident("syn2025"))
        #expect(!settings.isKeepResident("ud"))
        #expect(settings.keepResidentCorpora == ["syn2025"])
    }

    @Test func sourceLabels() {
        #expect(CorporaSettingsViewController.sourceTitle(.built) == "Built by Korpora")
        #expect(CorporaSettingsViewController.sourceTitle(.added(registryFile: URL(fileURLWithPath: "/x"))) == "Added")
        #expect(CorporaSettingsViewController.sourceTitle(.environment(directory: URL(fileURLWithPath: "/x"))) == "Environment")
    }

    @Test func migrationCarriesOldDirectoriesAndFlagsOverOnce() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CorpusListSettingsTests-\(UUID().uuidString)")
        let built = root.appendingPathComponent("built")
        let added = root.appendingPathComponent("added")
        let oldDirectory = root.appendingPathComponent("old-registry")
        for dir in [built, added, oldDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let saved = ["KORPORA_COMPILED_CORPORA_DIRECTORY", "KORPORA_ADDED_CORPORA_DIRECTORY", "MANATEE_REGISTRY"]
            .map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? fm.removeItem(at: root)
        }
        setenv("KORPORA_COMPILED_CORPORA_DIRECTORY", built.path, 1)
        setenv("KORPORA_ADDED_CORPORA_DIRECTORY", added.path, 1)

        // A corpus Korpora built, flagged the old way (corpus-meta.json).
        let data = CompiledCorpusStore.dataDirectory(for: "mine")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try "NAME \"mine\"\nPATH \"\(data.path)\"\n".write(
            to: built.appendingPathComponent("mine"), atomically: true, encoding: .utf8)
        try CompiledCorpusStore.setMetadata(.init(keepResident: true), for: "mine")
        // A corpus in a directory the old setting listed.
        let theirs = oldDirectory.appendingPathComponent("theirs.data")
        try fm.createDirectory(at: theirs, withIntermediateDirectories: true)
        try "NAME \"theirs\"\nPATH \"\(theirs.path)\"\n".write(
            to: oldDirectory.appendingPathComponent("theirs"), atomically: true, encoding: .utf8)

        let defaults = freshDefaults()
        defaults.set([oldDirectory.path], forKey: "corpusRegistryDirectories")
        let settings = AppSettings(defaults: defaults)
        settings.migrateCorpusList()

        let names = Dictionary(uniqueKeysWithValues: settings.corpusLibraryEntries().map { ($0.name, $0.origin) })
        #expect(names["mine"] == .built)
        if case .added? = names["theirs"] {} else { Issue.record("theirs should be an added corpus") }
        #expect(settings.keepResidentCorpora == ["mine"])
        #expect(defaults.object(forKey: "corpusRegistryDirectories") == nil)

        // Once only: a corpus added by hand afterwards isn't re-migrated,
        // and removing the flag isn't undone.
        settings.setKeepResident(false, for: "mine")
        settings.migrateCorpusList()
        #expect(settings.keepResidentCorpora.isEmpty)
    }

    /// The Corpora pane refreshes itself every 2 seconds (memory gauge and
    /// the Keep in Memory checkboxes). It used to `reloadData()` the whole
    /// table each time, which cleared the selection before "\u{2212}" could be
    /// clicked (macOS 15 smoke test of 0.2).
    @MainActor @Test func selectionSurvivesTheRefreshTimerAndReloads() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CorpusListSettingsTests-\(UUID().uuidString)")
        let built = root.appendingPathComponent("built")
        try fm.createDirectory(at: built, withIntermediateDirectories: true)
        let saved = ["KORPORA_COMPILED_CORPORA_DIRECTORY", "KORPORA_ADDED_CORPORA_DIRECTORY"]
            .map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? fm.removeItem(at: root)
        }
        setenv("KORPORA_COMPILED_CORPORA_DIRECTORY", built.path, 1)
        setenv("KORPORA_ADDED_CORPORA_DIRECTORY", root.appendingPathComponent("added").path, 1)
        for name in ["one", "two", "three"] {
            try "NAME \"\(name)\"\nPATH \"\(root.path)/\(name).data\"\n".write(
                to: built.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let controller = CorporaSettingsViewController()
        _ = controller.view
        let table = controller.tableView
        var target: Int?
        for row in 0..<table.numberOfRows {
            table.selectRowIndexes([row], byExtendingSelection: false)
            if controller.selectedCorpusName == "two" { target = row }
        }
        let row = try #require(target)
        table.selectRowIndexes([row], byExtendingSelection: false)

        controller.refreshMemoryDependentColumn()
        #expect(controller.selectedCorpusName == "two")
        controller.reloadCorpora()
        #expect(controller.selectedCorpusName == "two")
    }
}
