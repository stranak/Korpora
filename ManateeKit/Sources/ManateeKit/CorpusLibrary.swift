import Foundation

/// Every corpus the app can open, whoever compiled it - the file-level half
/// of Settings → Corpora (docs/project-plan.md, "Corpus Settings UX: one
/// corpus list").
///
/// A corpus is a Manatee registry file (its name is the corpus name) plus
/// the compiled data its `PATH` points at. Three places provide them, in
/// Manatee lookup order:
/// - **built**: corpora Korpora compiled itself, in
///   `CompiledCorpusStore.baseDirectory`;
/// - **added**: corpora compiled elsewhere (`encodevert`, a NoSketch or
///   KonText installation), each a symlink to its registry file in
///   `addedDirectory`, so one corpus can be added without its neighbours;
/// - **environment**: directories in an inherited `MANATEE_REGISTRY` (the
///   Xcode scheme's DevCorpus, a shell launch), which the app lists but
///   doesn't manage.
/// All three are plain `MANATEE_REGISTRY` directories, so Manatee's own
/// lookup and `CorpusRegistry` need nothing special; `searchPath` is what
/// the app puts in the environment.
public enum CorpusLibrary {
    private static let addedEnvironmentKey = "KORPORA_ADDED_CORPORA_DIRECTORY"

    /// Symlinks to registry files of corpora compiled outside Korpora.
    /// Finder-visible, like `CompiledCorpusStore.baseDirectory`.
    /// `KORPORA_ADDED_CORPORA_DIRECTORY` overrides it (tests, CLI).
    public static var addedDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[addedEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Korpora/AddedCorpora", isDirectory: true)
    }

    /// Where a built corpus goes when it's removed but its data kept.
    /// A subdirectory, so Manatee's registry scan (which skips them) no
    /// longer sees it.
    public static var removedDirectory: URL {
        CompiledCorpusStore.baseDirectory.appendingPathComponent("Removed", isDirectory: true)
    }

    public enum Origin: Sendable, Equatable {
        case built
        /// The registry file the symlink points at.
        case added(registryFile: URL)
        /// The inherited `MANATEE_REGISTRY` directory it was found in.
        case environment(directory: URL)
    }

    public struct Entry: Sendable, Equatable {
        public var name: String
        public var origin: Origin
        /// The registry file as Manatee reads it (for an added corpus, the
        /// symlink).
        public var registryFile: URL
        /// The registry's `PATH`: the compiled indices. Nil when the
        /// registry file has none Korpora can read.
        public var dataDirectory: URL?

        public var isRemovable: Bool {
            if case .environment = origin { return false }
            return true
        }
    }

    public enum LibraryError: Error, CustomStringConvertible, Equatable {
        case nameTaken(String)
        case notARegistryFile(URL)
        case notRemovable(String)

        public var description: String {
            switch self {
            case .nameTaken(let name):
                return "A corpus named \u{201C}\(name)\u{201D} is already in Korpora."
            case .notARegistryFile(let url):
                return "\u{201C}\(url.lastPathComponent)\u{201D} isn't a corpus registry file (it has no PATH)."
            case .notRemovable(let name):
                return "\u{201C}\(name)\u{201D} comes from the MANATEE_REGISTRY environment variable, "
                    + "so Korpora can't remove it."
            }
        }
    }

    // MARK: Listing

    /// The directories to put in `MANATEE_REGISTRY`: built, added, then any
    /// inherited ones not already among them. Earlier wins for a name
    /// found twice, as in Manatee's own lookup.
    public static func searchPath(inherited: [String]) -> [String] {
        var directories = [CompiledCorpusStore.baseDirectory.path, addedDirectory.path]
        for directory in inherited where !directory.isEmpty && !directories.contains(directory) {
            directories.append(directory)
        }
        return directories
    }

    /// Every corpus, in lookup order; a name shadowed by an earlier
    /// directory is left out, since Manatee would never open it.
    /// - Parameter inherited: the `MANATEE_REGISTRY` the app started with.
    public static func entries(inherited: [String]) -> [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        func append(_ entry: Entry) {
            if seen.insert(entry.name).inserted { result.append(entry) }
        }
        for name in registryNames(in: CompiledCorpusStore.baseDirectory) {
            let file = CompiledCorpusStore.baseDirectory.appendingPathComponent(name)
            append(Entry(name: name, origin: .built, registryFile: file, dataDirectory: dataDirectory(ofRegistry: file)))
        }
        for name in registryNames(in: addedDirectory) {
            let link = addedDirectory.appendingPathComponent(name)
            let target = link.resolvingSymlinksInPath()
            append(Entry(name: name, origin: .added(registryFile: target), registryFile: link,
                         dataDirectory: dataDirectory(ofRegistry: target)))
        }
        let own = Set([CompiledCorpusStore.baseDirectory.path, addedDirectory.path])
        for directory in inherited where !own.contains(directory) {
            let dir = URL(fileURLWithPath: directory, isDirectory: true)
            for name in registryNames(in: dir) {
                let file = dir.appendingPathComponent(name)
                append(Entry(name: name, origin: .environment(directory: dir), registryFile: file,
                             dataDirectory: dataDirectory(ofRegistry: file)))
            }
        }
        return result
    }

    /// Registry files directly in `directory`: regular files (or symlinks
    /// to them), not hidden, not subdirectories - Manatee's own rule.
    static func registryNames(in directory: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            // fileExists follows symlinks: a dangling one reads as missing.
            return FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }.sorted()
    }

    // MARK: PATH

    /// The registry file's `PATH` value, as a directory URL. Manatee's
    /// registry syntax is `KEY value` or `KEY "value"`, one per line at the
    /// top level; `PATH` there is the corpus's own (attribute blocks have
    /// no `PATH`). A relative `PATH` is taken relative to the registry
    /// file's directory.
    public static func dataDirectory(ofRegistry file: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        guard let value = topLevelValue("PATH", in: text) else { return nil }
        let path = value.hasPrefix("/") ? value
            : file.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(value).path
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static func topLevelValue(_ key: String, in text: String) -> String? {
        var depth = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if depth == 0, line.hasPrefix(key + " ") || line.hasPrefix(key + "\t") {
                var value = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), let end = value.dropFirst().firstIndex(of: "\"") {
                    value = String(value[value.index(after: value.startIndex)..<end])
                }
                return value
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
        }
        return nil
    }

    /// `text` with its top-level `PATH` replaced (quoted), for a registry
    /// file whose data moved.
    static func replacingPath(in text: String, with path: String) -> String {
        var depth = 0
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if depth == 0, line.hasPrefix("PATH ") || line.hasPrefix("PATH\t") {
                lines[i] = "PATH \"\(path)\""
                break
            }
            if !line.hasPrefix("#") {
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Adding

    /// Adds a corpus compiled elsewhere, by its registry file. The corpus
    /// name is the file name, as for Manatee.
    /// - Parameter taken: names already in use (`entries(inherited:)`),
    ///   refused as `nameTaken`.
    @discardableResult
    public static func add(registryFile: URL, taken: Set<String>) throws -> Entry {
        let file = registryFile.resolvingSymlinksInPath()
        let name = file.lastPathComponent
        guard !taken.contains(name) else { throw LibraryError.nameTaken(name) }
        guard let data = dataDirectory(ofRegistry: file) else { throw LibraryError.notARegistryFile(file) }
        try FileManager.default.createDirectory(at: addedDirectory, withIntermediateDirectories: true)
        let link = addedDirectory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        return Entry(name: name, origin: .added(registryFile: file), registryFile: link, dataDirectory: data)
    }

    /// Adds every registry file directly in `directory` whose name is free.
    /// Returns what was added and what was skipped (name taken, not a
    /// registry file).
    public static func addAll(inDirectory directory: URL, taken: Set<String>)
        -> (added: [Entry], skipped: [(name: String, reason: LibraryError)])
    {
        var taken = taken
        var added: [Entry] = []
        var skipped: [(String, LibraryError)] = []
        for name in registryNames(in: directory) {
            do {
                let entry = try add(registryFile: directory.appendingPathComponent(name), taken: taken)
                added.append(entry)
                taken.insert(name)
            } catch let error as LibraryError {
                skipped.append((name, error))
            } catch {
                skipped.append((name, .notARegistryFile(directory.appendingPathComponent(name))))
            }
        }
        return (added, skipped)
    }

    /// Carries the old "Corpus registry directories" setting over: every
    /// registry file in those directories becomes an added corpus. Korpora's
    /// own directories are skipped (they're always searched), as are names
    /// already taken; directories that don't exist right now (an unmounted
    /// volume) are reported so the caller can log them.
    public static func adoptRegistryDirectories(_ directories: [String], taken: Set<String>)
        -> (added: [Entry], missing: [String])
    {
        let own = Set([CompiledCorpusStore.baseDirectory.path, addedDirectory.path])
        var taken = taken
        var added: [Entry] = []
        var missing: [String] = []
        for directory in directories where !directory.isEmpty && !own.contains(directory) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                missing.append(directory)
                continue
            }
            let result = addAll(inDirectory: URL(fileURLWithPath: directory, isDirectory: true), taken: taken)
            added += result.added
            taken.formUnion(result.added.map(\.name))
        }
        return (added, missing)
    }

    // MARK: Removing

    /// Removes a corpus from Korpora.
    /// - `deleteData: true` deletes its registry file and compiled data
    ///   (for an added corpus, the files the symlink led to, too).
    /// - `deleteData: false` keeps them: an added corpus loses only its
    ///   symlink; a built one moves to `removedDirectory/<name>/` with its
    ///   `PATH` rewritten, so it can be added back.
    /// - Returns: for a kept built corpus, its registry file's new place.
    @discardableResult
    public static func remove(_ entry: Entry, deleteData: Bool) throws -> URL? {
        let fm = FileManager.default
        switch entry.origin {
        case .environment:
            throw LibraryError.notRemovable(entry.name)
        case .added(let registryFile):
            try fm.removeItem(at: entry.registryFile)
            if deleteData {
                if let data = entry.dataDirectory { try? fm.removeItem(at: data) }
                try? fm.removeItem(at: registryFile)
            }
            return nil
        case .built:
            if deleteData {
                try CompiledCorpusStore.remove(entry.name)
                return nil
            }
            return try moveToRemoved(entry)
        }
    }

    private static func moveToRemoved(_ entry: Entry) throws -> URL {
        let fm = FileManager.default
        var destination = removedDirectory.appendingPathComponent(entry.name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = removedDirectory.appendingPathComponent("\(entry.name) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        // The built layout is `<name>` + `<name>.data/{data, corpus-meta.json}`;
        // move the whole `.data` folder, then point PATH at its `data`.
        let support = CompiledCorpusStore.baseDirectory.appendingPathComponent("\(entry.name).data", isDirectory: true)
        let movedSupport = destination.appendingPathComponent("\(entry.name).data", isDirectory: true)
        if fm.fileExists(atPath: support.path) {
            try fm.moveItem(at: support, to: movedSupport)
        }
        let text = try String(contentsOf: entry.registryFile, encoding: .utf8)
        let newPath = movedSupport.appendingPathComponent("data", isDirectory: true).path
        let movedRegistry = destination.appendingPathComponent(entry.name)
        try replacingPath(in: text, with: newPath).write(to: movedRegistry, atomically: true, encoding: .utf8)
        try fm.removeItem(at: entry.registryFile)
        return movedRegistry
    }
}
