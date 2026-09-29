import Foundation
import ManateeKit

/// Owns the app-lifetime side of `CorpusMemoryResidency`: re-warming corpora
/// flagged `keepResident` at launch (available memory can differ session to
/// session, so the guard is re-checked, not just trusted from whenever the
/// flag was originally set), and backing off under real system memory
/// pressure as a safety net (`warm(directory:)` is only ever a hint - if the
/// OS is genuinely under pressure, get out of the way rather than compete
/// with it).
final class CorpusResidencyManager {
    static let shared = CorpusResidencyManager()

    private var pressureSource: DispatchSourceMemoryPressure?

    private init() {}

    func start() {
        rewarmFlaggedCorpora()
        observeMemoryPressure()
    }

    /// Corpora flagged "Keep in Memory" that can be found now, with their
    /// data directories - built or added, no difference.
    private func flaggedCorpora() -> [(name: String, directory: URL)] {
        AppSettings.shared.corpusLibraryEntries().compactMap { entry in
            guard AppSettings.shared.isKeepResident(entry.name), let directory = entry.dataDirectory else { return nil }
            return (entry.name, directory)
        }
    }

    private func rewarmFlaggedCorpora() {
        for (name, directory) in flaggedCorpora() {
            let size = CorpusMemoryResidency.directorySize(directory)
            guard CorpusMemoryResidency.canKeepResident(
                sizeBytes: size, currentlyAvailable: CorpusMemoryResidency.availableMemory(),
                minimumFreeAfter: AppSettings.shared.minimumFreeMemoryAfterResidency) else {
                NSLog("Korpora: skipping launch-time warm of \"%@\" - not enough free memory right now.", name)
                continue
            }
            Task.detached(priority: .utility) {
                try? await CorpusMemoryResidency.warm(directory: directory)
            }
        }
    }

    private func observeMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard source.data.contains(.critical) else { return }
            self?.coolDownAllResidentCorpora()
        }
        source.resume()
        pressureSource = source
    }

    private func coolDownAllResidentCorpora() {
        for (name, directory) in flaggedCorpora() {
            NSLog("Korpora: system memory pressure critical - releasing warmed pages for \"%@\".", name)
            CorpusMemoryResidency.unwarm(directory: directory)
        }
    }
}
