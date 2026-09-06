import Foundation

/// Where corpora imported via `CorpusImporter` live. `baseDirectory` doubles
/// as a real Manatee registry directory (one registry *file* per corpus,
/// directly inside it - see `CorpusRegistry`'s doc comment on why
/// subdirectories don't count there), so anything imported here shows up in
/// `CorpusRegistry.availableCorpusNames()` automatically once `baseDirectory`
/// is added to `MANATEE_REGISTRY` - no separate wiring needed. The compiled
/// binary indices and our own per-corpus bookkeeping live in a `.indices`
/// subdirectory instead, since Manatee's registry scan skips directories -
/// this keeps `baseDirectory` itself Finder-browsable as just "one file per
/// corpus" rather than being cluttered with the (potentially huge) compiled
/// data.
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

    private static func indexDirectory(for name: String) -> URL {
        baseDirectory.appendingPathComponent(".indices/\(name)", isDirectory: true)
    }

    /// Where `encodevert` writes this corpus's compiled binary indices - the
    /// `PATH` a generated registry file points at.
    public static func dataDirectory(for name: String) -> URL {
        indexDirectory(for: name).appendingPathComponent("data", isDirectory: true)
    }

    private static func metadataURL(for name: String) -> URL {
        indexDirectory(for: name).appendingPathComponent("corpus-meta.json")
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
        try? FileManager.default.removeItem(at: indexDirectory(for: name))
    }
}
