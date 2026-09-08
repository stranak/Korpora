import Foundation

/// Where this app keeps the subcorpus files it creates (see
/// `Corpus.createSubcorpus`/`openSubcorpus`) - one `.subc` file per
/// subcorpus, grouped by parent corpus name. Not a Manatee concept itself;
/// Manatee only cares about the path it's given.
public enum SubcorpusStore {
    public static var baseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Korpora/Subcorpora", isDirectory: true)
    }

    public static func directory(for corpusName: String) -> URL {
        baseDirectory.appendingPathComponent(corpusName, isDirectory: true)
    }

    public static func path(for corpusName: String, subcorpusName: String) -> String {
        directory(for: corpusName).appendingPathComponent("\(subcorpusName).subc").path
    }

    /// Names of subcorpora already created for `corpusName` (without the
    /// `.subc` extension), sorted for stable display.
    public static func availableSubcorpora(for corpusName: String) -> [String] {
        let directory = directory(for: corpusName)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return entries
            .filter { $0.hasSuffix(".subc") }
            .map { String($0.dropLast(".subc".count)) }
            .sorted()
    }
}
