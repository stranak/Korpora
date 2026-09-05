import Cocoa

/// Backs the Settings window; persisted via `UserDefaults`.
final class AppSettings {
    static let shared = AppSettings()
    static let didChangeNotification = Notification.Name("AppSettingsDidChange")

    private enum Key {
        static let corpusRegistryDirectories = "corpusRegistryDirectories"
        static let resultsFontName = "resultsFontName"
        static let resultsFontSize = "resultsFontSize"
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

    /// Applies `corpusRegistryDirectories` to the process environment - the
    /// only thing Manatee's own registry lookup actually reads, fresh on
    /// every call (see `CorpusRegistry`'s doc comment). Only overrides the
    /// inherited value when the user has actually set something, so the
    /// Xcode-scheme dev override (`Corpora/project.yml`) keeps working until
    /// a real preference is set.
    func applyEnvironment() {
        let directories = corpusRegistryDirectories.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !directories.isEmpty else { return }
        setenv("MANATEE_REGISTRY", directories.joined(separator: ":"), 1)
    }
}
