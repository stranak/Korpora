import Foundation

/// Where corpora imported via `CorpusImporter` live. `baseDirectory` doubles
/// as a real Manatee registry directory (one registry *file* per corpus,
/// directly inside it - see `CorpusRegistry`'s doc comment on why
/// subdirectories don't count there), so anything imported here shows up in
/// `CorpusRegistry.availableCorpusNames()` automatically once `baseDirectory`
/// is added to `MANATEE_REGISTRY` - no separate wiring needed. The compiled
/// binary indices and our own per-corpus bookkeeping live alongside it in a
/// visible `<name>.data` sibling directory (Manatee's registry scan already
/// skips directories, so this doesn't need to be hidden to avoid being
/// mistaken for a corpus) - everything under `baseDirectory` must stay
/// Finder-browsable, per this project's own convention (see
/// `Corpora/DevCorpus/`, deliberately not `.devcorpus/`): a user should never
/// have to know to press Cmd-Shift-. to find their own compiled corpus data,
/// especially when Settings itself names this exact directory as "where
/// compiled corpora live."
public enum CompiledCorpusStore {
    private static let environmentKey = "CORPORA_COMPILED_CORPORA_DIRECTORY"

    /// Reads a `Corpora`-app-set environment variable (mirrors how
    /// `CorpusRegistry` reads `MANATEE_REGISTRY` fresh on every call, rather
    /// than this package owning persisted state itself - it has no
    /// UserDefaults dependency) with a sensible default so
    /// `manateekit-cli`/tests still have somewhere to write.
    public static var baseDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Corpora/CompiledCorpora", isDirectory: true)
    }

    /// The registry file itself - must sit directly under `baseDirectory`
    /// (not in a subdirectory) to be found by Manatee's own registry scan.
    public static func registryPath(for name: String) -> URL {
        baseDirectory.appendingPathComponent(name, isDirectory: false)
    }

    /// A visible sibling of `registryPath(for:)` - `<name>.data`, not
    /// `.data/<name>` or any other leading-dot form, since only a name that
    /// *starts* with a dot is hidden by macOS/Finder.
    private static func supportDirectory(for name: String) -> URL {
        baseDirectory.appendingPathComponent("\(name).data", isDirectory: true)
    }

    /// Where `encodevert` writes this corpus's compiled binary indices - the
    /// `PATH` a generated registry file points at.
    public static func dataDirectory(for name: String) -> URL {
        supportDirectory(for: name).appendingPathComponent("data", isDirectory: true)
    }

    private static func metadataURL(for name: String) -> URL {
        supportDirectory(for: name).appendingPathComponent("corpus-meta.json")
    }

    public struct Metadata: Codable, Sendable, Equatable {
        public var keepResident: Bool
        public init(keepResident: Bool = false) {
            self.keepResident = keepResident
        }
    }

    public static func metadata(for name: String) -> Metadata {
        guard let data = try? Data(contentsOf: metadataURL(for: name)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return Metadata()
        }
        return metadata
    }

    public static func setMetadata(_ metadata: Metadata, for name: String) throws {
        let url = metadataURL(for: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: url)
    }

    /// Names of corpora imported via `CorpusImporter`, sorted for stable
    /// display - scoped to just this directory (unlike
    /// `CorpusRegistry.availableCorpusNames()`, which lists every configured
    /// `MANATEE_REGISTRY` directory together), since the Settings UI needs
    /// to show/manage only the ones this app actually compiled.
    public static func availableCorpusNames() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: baseDirectory.path) else {
            return []
        }
        return entries.filter { entry in
            guard !entry.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            let path = baseDirectory.appendingPathComponent(entry).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }.sorted()
    }

    /// Removes a corpus's registry file, compiled indices, and metadata.
    public static func remove(_ name: String) throws {
        try? FileManager.default.removeItem(at: registryPath(for: name))
        try? FileManager.default.removeItem(at: supportDirectory(for: name))
    }
}
