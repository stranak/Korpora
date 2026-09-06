import Cocoa
import ManateeKit

/// Backs the Settings window; persisted via `UserDefaults`.
final class AppSettings {
    static let shared = AppSettings()
    static let didChangeNotification = Notification.Name("AppSettingsDidChange")

    private enum Key {
        static let corpusRegistryDirectories = "corpusRegistryDirectories"
        static let resultsFontName = "resultsFontName"
        static let resultsFontSize = "resultsFontSize"
        static let compiledCorporaDirectory = "compiledCorporaDirectory"
        static let minimumFreeMemoryAfterResidency = "minimumFreeMemoryAfterResidency"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Mirrors Manatee's own `MANATEE_REGISTRY` grammar directly (an ordered
    /// list of directories to search for corpus registry files - see
    /// `corp/loadconf.cc` and `ManateeKit.CorpusRegistry`) rather than
    /// inventing a different shape for the same concept.
    var corpusRegistryDirectories: [String] {
        get { defaults.stringArray(forKey: Key.corpusRegistryDirectories) ?? [] }
        set {
            defaults.set(newValue, forKey: Key.corpusRegistryDirectories)
            applyEnvironment()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var resultsFontName: String {
        get { defaults.string(forKey: Key.resultsFontName) ?? "Menlo" }
        set {
            defaults.set(newValue, forKey: Key.resultsFontName)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var resultsFontSize: Double {
        get {
            let value = defaults.double(forKey: Key.resultsFontSize)
            return value > 0 ? value : 12
        }
        set {
            defaults.set(newValue, forKey: Key.resultsFontSize)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var resultsFont: NSFont {
        NSFont(name: resultsFontName, size: CGFloat(resultsFontSize))
            ?? .monospacedSystemFont(ofSize: CGFloat(resultsFontSize), weight: .regular)
    }

    /// Where corpora imported via `CorpusImporter` are compiled to - passed
    /// to `ManateeKit.CompiledCorpusStore` via an environment variable
    /// (mirrors `corpusRegistryDirectories`'s own env-var-mediated design,
    /// keeping ManateeKit free of a UserDefaults dependency). `nil`/empty
    /// means "use `CompiledCorpusStore.baseDirectory`'s own built-in
    /// default" - still a real, working location, just not user-customized.
    var compiledCorporaDirectory: String? {
        get { defaults.string(forKey: Key.compiledCorporaDirectory) }
        set {
            defaults.set(newValue, forKey: Key.compiledCorporaDirectory)
            applyEnvironment()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Minimum free memory (bytes) a corpus's "Keep in Memory" toggle must
    /// leave available - see `ManateeKit.CorpusMemoryResidency.
    /// canKeepResident`. Defaults to 10 GB.
    var minimumFreeMemoryAfterResidency: UInt64 {
        get {
            let value = defaults.integer(forKey: Key.minimumFreeMemoryAfterResidency)
            return value > 0 ? UInt64(value) : 10_000_000_000
        }
        set {
            defaults.set(Int(newValue), forKey: Key.minimumFreeMemoryAfterResidency)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Applies `corpusRegistryDirectories`/`compiledCorporaDirectory` to the
    /// process environment - the only thing Manatee's own registry lookup
    /// actually reads, fresh on every call (see `CorpusRegistry`'s doc
    /// comment). The compiled-corpora directory is always folded in (an
    /// imported corpus should just work without a separate trip to General
    /// settings), merged on top of whatever `MANATEE_REGISTRY` already is
    /// rather than replacing it - so the Xcode-scheme dev override
    /// (`Corpora/project.yml`, which points at `DevCorpus`) keeps working
    /// until/alongside a real preference being set, instead of being
    /// clobbered by this.
    func applyEnvironment() {
        let compiledDirectory = compiledCorporaDirectory?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? compiledCorporaDirectory! : CompiledCorpusStore.baseDirectory.path
        setenv("CORPORA_COMPILED_CORPORA_DIRECTORY", compiledDirectory, 1)

        var directories = corpusRegistryDirectories.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let inherited = ProcessInfo.processInfo.environment["MANATEE_REGISTRY"]?
            .split(separator: ":").map(String.init) ?? []
        for directory in inherited where !directories.contains(directory) {
            directories.append(directory)
        }
        if !directories.contains(compiledDirectory) {
            directories.append(compiledDirectory)
        }
        setenv("MANATEE_REGISTRY", directories.joined(separator: ":"), 1)
    }
}
