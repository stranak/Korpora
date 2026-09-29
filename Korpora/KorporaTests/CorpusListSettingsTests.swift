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
}
