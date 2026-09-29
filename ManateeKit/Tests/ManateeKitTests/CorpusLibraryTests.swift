import XCTest

@testable import ManateeKit

/// File-level behavior of the unified corpus list (docs/project-plan.md,
/// "Corpus Settings UX"): built, added and environment corpora listed
/// together, and added/removed alike. Pure file operations in temporary
/// directories - no engine, no real registry.
final class CorpusLibraryTests: XCTestCase {
    private var root: URL!
    private var builtDir: URL!
    private var addedDir: URL!
    private var elsewhere: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CorpusLibraryTests-\(UUID().uuidString)")
        builtDir = root.appendingPathComponent("built")
        addedDir = root.appendingPathComponent("added")
        elsewhere = root.appendingPathComponent("elsewhere")
        for dir in [builtDir!, addedDir!, elsewhere!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        setenv("KORPORA_COMPILED_CORPORA_DIRECTORY", builtDir.path, 1)
        setenv("KORPORA_ADDED_CORPORA_DIRECTORY", addedDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("KORPORA_COMPILED_CORPORA_DIRECTORY")
        unsetenv("KORPORA_ADDED_CORPORA_DIRECTORY")
        try? FileManager.default.removeItem(at: root)
    }

    /// A registry file + a data directory with one file in it, the way
    /// `encodevert` leaves a corpus.
    @discardableResult
    private func makeCorpus(named name: String, registryIn dir: URL, dataAt data: URL,
                            extraTopLevel: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("index".utf8).write(to: data.appendingPathComponent("word.lex"))
        let file = dir.appendingPathComponent(name)
        try """
            NAME "\(name)"
            \(extraTopLevel)
            PATH "\(data.path)"
            ATTRIBUTE word
            ATTRIBUTE lemma {
                PATH "/should/not/be/read"
            }
            """.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A corpus laid out the way `CorpusImporter` leaves one.
    private func makeBuilt(_ name: String) throws {
        let data = CompiledCorpusStore.dataDirectory(for: name)
        try makeCorpus(named: name, registryIn: builtDir, dataAt: data)
        try CompiledCorpusStore.setMetadata(.init(keepResident: true), for: name)
    }

    // MARK: PATH

    func testDataDirectoryReadsTheTopLevelPathOnly() throws {
        let file = try makeCorpus(named: "c", registryIn: elsewhere, dataAt: elsewhere.appendingPathComponent("c.d"))
        XCTAssertEqual(CorpusLibrary.dataDirectory(ofRegistry: file)?.path,
                       elsewhere.appendingPathComponent("c.d").standardizedFileURL.path)
    }

    func testUnquotedAndRelativePaths() throws {
        let unquoted = elsewhere.appendingPathComponent("u")
        try "NAME u\nPATH /abs/u.data\n".write(to: unquoted, atomically: true, encoding: .utf8)
        XCTAssertEqual(CorpusLibrary.dataDirectory(ofRegistry: unquoted)?.path, "/abs/u.data")
        let relative = elsewhere.appendingPathComponent("r")
        try "PATH \"r.data\"\n".write(to: relative, atomically: true, encoding: .utf8)
        XCTAssertEqual(CorpusLibrary.dataDirectory(ofRegistry: relative)?.path,
                       elsewhere.appendingPathComponent("r.data").standardizedFileURL.path)
    }

    func testNoPathMeansNotARegistryFile() throws {
        let file = elsewhere.appendingPathComponent("notes.txt")
        try "just some text\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(CorpusLibrary.dataDirectory(ofRegistry: file))
        XCTAssertThrowsError(try CorpusLibrary.add(registryFile: file, taken: [])) { error in
            XCTAssertEqual(error as? CorpusLibrary.LibraryError, .notARegistryFile(file.resolvingSymlinksInPath()))
        }
        XCTAssertTrue(CorpusLibrary.registryNames(in: addedDir).isEmpty)
    }

    func testReplacingPathTouchesOnlyTheTopLevel() {
        let text = "NAME x\nPATH \"/old\"\nATTRIBUTE a {\n  PATH \"/attr\"\n}\n"
        XCTAssertEqual(CorpusLibrary.replacingPath(in: text, with: "/new"),
                       "NAME x\nPATH \"/new\"\nATTRIBUTE a {\n  PATH \"/attr\"\n}\n")
    }

    // MARK: Listing

    func testListsBuiltAddedAndEnvironmentTogether() throws {
        try makeBuilt("mine")
        let outside = try makeCorpus(named: "theirs", registryIn: elsewhere,
                                     dataAt: elsewhere.appendingPathComponent("theirs.data"))
        try CorpusLibrary.add(registryFile: outside, taken: ["mine"])
        let envDir = root.appendingPathComponent("env")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
        try makeCorpus(named: "fromshell", registryIn: envDir, dataAt: envDir.appendingPathComponent("s.data"))

        let entries = CorpusLibrary.entries(inherited: [envDir.path])
        XCTAssertEqual(entries.map(\.name), ["mine", "theirs", "fromshell"])
        XCTAssertEqual(entries[0].origin, .built)
        XCTAssertEqual(entries[1].origin, .added(registryFile: outside.resolvingSymlinksInPath()))
        if case .environment(let dir) = entries[2].origin {
            XCTAssertEqual(dir.standardizedFileURL.path, envDir.standardizedFileURL.path)
        } else {
            XCTFail("expected environment origin")
        }
        XCTAssertEqual(entries.map(\.isRemovable), [true, true, false])
        XCTAssertNotNil(entries[0].dataDirectory)
    }

    /// The corpora directories themselves may be in the inherited path
    /// (the app puts them there): they're not "environment" corpora.
    func testOwnDirectoriesInTheInheritedPathAreNotEnvironment() throws {
        try makeBuilt("mine")
        let entries = CorpusLibrary.entries(inherited: [builtDir.path, addedDir.path])
        XCTAssertEqual(entries.map(\.origin), [.built])
    }

    /// Manatee opens the first registry file with a name, so a shadowed one
    /// isn't listed.
    func testAnEarlierDirectoryShadowsALaterOne() throws {
        try makeBuilt("dup")
        let outside = try makeCorpus(named: "dup", registryIn: elsewhere, dataAt: elsewhere.appendingPathComponent("d.data"))
        XCTAssertThrowsError(try CorpusLibrary.add(registryFile: outside, taken: ["dup"])) { error in
            XCTAssertEqual(error as? CorpusLibrary.LibraryError, .nameTaken("dup"))
        }
        XCTAssertEqual(CorpusLibrary.entries(inherited: []).map(\.name), ["dup"])
    }

    func testSearchPathOrder() {
        XCTAssertEqual(CorpusLibrary.searchPath(inherited: ["/x", builtDir.path, "", "/y"]),
                       [builtDir.path, addedDir.path, "/x", "/y"])
    }

    func testDanglingSymlinkIsNotListed() throws {
        let outside = try makeCorpus(named: "gone", registryIn: elsewhere, dataAt: elsewhere.appendingPathComponent("g.data"))
        try CorpusLibrary.add(registryFile: outside, taken: [])
        try FileManager.default.removeItem(at: outside)
        XCTAssertTrue(CorpusLibrary.entries(inherited: []).isEmpty)
    }

    // MARK: Adding

    func testAddMakesASymlinkAndLeavesTheOriginalAlone() throws {
        let outside = try makeCorpus(named: "theirs", registryIn: elsewhere,
                                     dataAt: elsewhere.appendingPathComponent("t.data"))
        let entry = try CorpusLibrary.add(registryFile: outside, taken: [])
        let link = addedDir.appendingPathComponent("theirs")
        XCTAssertEqual(entry.registryFile, link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       outside.resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testAddAllSkipsTakenNamesAndNonRegistryFiles() throws {
        try makeCorpus(named: "a", registryIn: elsewhere, dataAt: elsewhere.appendingPathComponent("a.d"))
        try makeCorpus(named: "b", registryIn: elsewhere, dataAt: elsewhere.appendingPathComponent("b.d"))
        try "readme\n".write(to: elsewhere.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        let result = CorpusLibrary.addAll(inDirectory: elsewhere, taken: ["b"])
        XCTAssertEqual(result.added.map(\.name), ["a"])
        XCTAssertEqual(Set(result.skipped.map(\.name)), ["b", "README"])
    }

    // MARK: Migrating the old registry-directories setting

    func testAdoptingOldRegistryDirectories() throws {
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try makeCorpus(named: "a", registryIn: elsewhere, dataAt: elsewhere.appendingPathComponent("a.data"))
        try makeCorpus(named: "dup", registryIn: elsewhere, dataAt: elsewhere.appendingPathComponent("dup.data"))
        try makeCorpus(named: "b", registryIn: second, dataAt: second.appendingPathComponent("b.data"))
        try makeCorpus(named: "dup", registryIn: second, dataAt: second.appendingPathComponent("dup2.data"))
        let gone = root.appendingPathComponent("unmounted").path

        // Korpora's own directories in the old list are ignored, and a name
        // found twice is added once, from the earlier directory.
        let result = CorpusLibrary.adoptRegistryDirectories(
            [builtDir.path, elsewhere.path, gone, second.path, ""], taken: [])
        XCTAssertEqual(result.added.map(\.name), ["a", "dup", "b"])
        XCTAssertEqual(result.missing, [gone])
        XCTAssertEqual(CorpusLibrary.entries(inherited: []).map(\.name), ["a", "b", "dup"])
        let dup = try XCTUnwrap(CorpusLibrary.entries(inherited: []).first { $0.name == "dup" })
        XCTAssertEqual(dup.origin, .added(registryFile: elsewhere.appendingPathComponent("dup").resolvingSymlinksInPath()))
    }

    // MARK: Removing - both kinds behave alike

    func testRemovingAnAddedCorpusKeepingItsData() throws {
        let data = elsewhere.appendingPathComponent("t.data")
        let outside = try makeCorpus(named: "t", registryIn: elsewhere, dataAt: data)
        let entry = try CorpusLibrary.add(registryFile: outside, taken: [])
        try CorpusLibrary.remove(entry, deleteData: false)
        XCTAssertTrue(CorpusLibrary.entries(inherited: []).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("word.lex").path))
    }

    func testRemovingAnAddedCorpusWithItsData() throws {
        let data = elsewhere.appendingPathComponent("t.data")
        let outside = try makeCorpus(named: "t", registryIn: elsewhere, dataAt: data)
        let entry = try CorpusLibrary.add(registryFile: outside, taken: [])
        try CorpusLibrary.remove(entry, deleteData: true)
        XCTAssertTrue(CorpusLibrary.entries(inherited: []).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
    }

    func testRemovingABuiltCorpusWithItsData() throws {
        try makeBuilt("mine")
        let entry = try XCTUnwrap(CorpusLibrary.entries(inherited: []).first)
        let data = try XCTUnwrap(entry.dataDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
        try CorpusLibrary.remove(entry, deleteData: true)
        XCTAssertTrue(CorpusLibrary.entries(inherited: []).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: builtDir.appendingPathComponent("mine.data").path))
    }

    /// Kept data moves out of the registry directory - so the corpus is gone
    /// from Korpora - and stays usable: the moved registry's PATH follows.
    func testRemovingABuiltCorpusKeepingItsData() throws {
        try makeBuilt("mine")
        let entry = try XCTUnwrap(CorpusLibrary.entries(inherited: []).first)
        let moved = try XCTUnwrap(try CorpusLibrary.remove(entry, deleteData: false))
        XCTAssertTrue(CorpusLibrary.entries(inherited: []).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: builtDir.appendingPathComponent("mine").path))
        XCTAssertEqual(moved.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Removed")
        let data = try XCTUnwrap(CorpusLibrary.dataDirectory(ofRegistry: moved))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("word.lex").path))
        // ...and it can be added back.
        let back = try CorpusLibrary.add(registryFile: moved, taken: [])
        XCTAssertEqual(back.name, "mine")
        XCTAssertEqual(CorpusLibrary.entries(inherited: []).map(\.name), ["mine"])
    }

    /// Removing twice under one name doesn't overwrite the earlier copy.
    func testRepeatedKeepRemovalsDoNotCollide() throws {
        try makeBuilt("mine")
        let first = try XCTUnwrap(try CorpusLibrary.remove(try XCTUnwrap(CorpusLibrary.entries(inherited: []).first),
                                                           deleteData: false))
        try makeBuilt("mine")
        let second = try XCTUnwrap(try CorpusLibrary.remove(try XCTUnwrap(CorpusLibrary.entries(inherited: []).first),
                                                            deleteData: false))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testEnvironmentCorporaCannotBeRemoved() throws {
        let envDir = root.appendingPathComponent("env")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
        try makeCorpus(named: "fromshell", registryIn: envDir, dataAt: envDir.appendingPathComponent("s.data"))
        let entry = try XCTUnwrap(CorpusLibrary.entries(inherited: [envDir.path]).first)
        XCTAssertThrowsError(try CorpusLibrary.remove(entry, deleteData: true)) { error in
            XCTAssertEqual(error as? CorpusLibrary.LibraryError, .notRemovable("fromshell"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: envDir.appendingPathComponent("fromshell").path))
    }
}
