import Foundation

/// Lists corpora that actually exist, so callers can offer a picker instead
/// of a free-text "corpus name" field that reads like it creates something.
///
/// Mirrors Manatee's own registry lookup (`corp/loadconf.cc`): `MANATEE_REGISTRY`
/// is a `:`-separated list of directories, each holding one file per corpus
/// (the file name is the corpus name); Manatee falls back to `/corpora/registry`
/// when the variable isn't set, so this does too. Subdirectories are skipped,
/// matching Manatee's own scan (it treats a directory entry as "not found").
public enum CorpusRegistry {
    public static func availableCorpusNames() -> [String] {
        let registry = ProcessInfo.processInfo.environment["MANATEE_REGISTRY"] ?? "/corpora/registry"
        var seen = Set<String>()
        var names: [String] = []
        for dir in registry.split(separator: ":") {
            let dirPath = String(dir)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { continue }
            for entry in entries.sorted() {
                var isDirectory: ObjCBool = false
                let path = dirPath + "/" + entry
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                if seen.insert(entry).inserted {
                    names.append(entry)
                }
            }
        }
        return names
    }
}
