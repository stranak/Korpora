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
        static let defaultLeftContext = "defaultLeftContext"
        static let defaultRightContext = "defaultRightContext"
        static let defaultViewMode = "defaultViewMode"
        static let defaultExtendedContextTokens = "defaultExtendedContextTokens"
        static let scriptFontOverrides = "scriptFontOverrides"
        static let positionalAttributeColor = "positionalAttributeColor"
        static let structuralAttributeColor = "structuralAttributeColor"
        static let usesAlternatingRowBackground = "usesAlternatingRowBackground"
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

    /// Seeds `ConcordanceDocument.leftContext`/`rightContext` for a
    /// brand-new document - see `ConcordanceDocument`'s property
    /// declarations, which read these at instance-creation time.
    var defaultLeftContext: Int {
        get {
            let value = defaults.integer(forKey: Key.defaultLeftContext)
            return value > 0 ? value : 10
        }
        set {
            defaults.set(newValue, forKey: Key.defaultLeftContext)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var defaultRightContext: Int {
        get {
            let value = defaults.integer(forKey: Key.defaultRightContext)
            return value > 0 ? value : 10
        }
        set {
            defaults.set(newValue, forKey: Key.defaultRightContext)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Seeds `ConcordanceDocument.viewMode` for a brand-new document -
    /// see `ConcordanceViewMode`.
    var defaultViewMode: ConcordanceViewMode {
        get { defaults.string(forKey: Key.defaultViewMode).flatMap(ConcordanceViewMode.init(rawValue:)) ?? .kwic }
        set {
            defaults.set(newValue.rawValue, forKey: Key.defaultViewMode)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// How many tokens of context each side to fetch for the "Extended
    /// Context…" row action (Phase 6.6) by default. Defaults to 50 -
    /// generous enough to see well past a truncated Left/Right cell
    /// without being a heavy fetch.
    var defaultExtendedContextTokens: Int {
        get {
            let value = defaults.integer(forKey: Key.defaultExtendedContextTokens)
            return value > 0 ? value : 50
        }
        set {
            defaults.set(newValue, forKey: Key.defaultExtendedContextTokens)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Per-script concordance font overrides (Unicode script `rawValue` →
    /// font name - see `UnicodeScript`), for a corpus mixing scripts where
    /// `resultsFont` alone isn't ideal for all of them. A script with no
    /// entry here just keeps using `resultsFont`.
    var scriptFontOverrides: [String: String] {
        get { defaults.dictionary(forKey: Key.scriptFontOverrides) as? [String: String] ?? [:] }
        set {
            defaults.set(newValue, forKey: Key.scriptFontOverrides)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// The color inline/hover positional attributes (e.g. "tag", "lemma")
    /// render in - see `KWICCellView`. Was hardcoded `.secondaryLabelColor`
    /// before this setting existed; that's still the default.
    var positionalAttributeColor: NSColor {
        get { color(forKey: Key.positionalAttributeColor) ?? .secondaryLabelColor }
        set { setColor(newValue, forKey: Key.positionalAttributeColor) }
    }

    /// The color the structural-attribute ("Doc") column renders in - see
    /// `KWICCellView.configureStructuralInfo`. Same default as
    /// `positionalAttributeColor` before this setting existed.
    var structuralAttributeColor: NSColor {
        get { color(forKey: Key.structuralAttributeColor) ?? .secondaryLabelColor }
        set { setColor(newValue, forKey: Key.structuralAttributeColor) }
    }

    /// Whether the concordance table stripes alternating rows - see
    /// `ConcordanceViewController.setUpTableView`. Defaults to `true`
    /// (unchanged from before this setting existed). A custom tint color
    /// for the stripe itself was considered and dropped - that needs
    /// custom row drawing (`NSTableView`'s own alternating colors aren't
    /// independently recolorable), not just a setting, and no native Mac
    /// app actually lets you customize this, so it wasn't worth the
    /// custom-drawing complexity for a look nobody else offers either.
    var usesAlternatingRowBackground: Bool {
        get {
            defaults.object(forKey: Key.usesAlternatingRowBackground) == nil
                ? true : defaults.bool(forKey: Key.usesAlternatingRowBackground)
        }
        set {
            defaults.set(newValue, forKey: Key.usesAlternatingRowBackground)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// `UserDefaults` has no native `NSColor` support - archives via
    /// `NSKeyedArchiver`/`Unarchiver` (`NSColor` conforms to
    /// `NSSecureCoding`), same general shape as every other property here,
    /// just with an extra encode/decode step. Returns nil (rather than a
    /// hardcoded fallback) when nothing's been set, so each color
    /// property above can supply its own semantically-meaningful default.
    private func color(forKey key: String) -> NSColor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private func setColor(_ color: NSColor, forKey key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
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
