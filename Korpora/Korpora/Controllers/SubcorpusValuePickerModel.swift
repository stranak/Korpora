import Foundation
import ManateeKit

/// What the New Subcorpus popover shows and remembers while the user picks
/// values (docs/project-plan.md, 6.9): which structure and attribute, the
/// list of that attribute's values, a search over it, and what's ticked -
/// per attribute, so switching attributes keeps earlier picks.
///
/// UI-free on purpose. The engine is reached through `Loaders`, so the
/// logic (when a list is complete and can be filtered locally, when it's
/// capped and needs an engine search, dropping answers to a question the
/// user has already moved on from) is tested with fake loaders.
@MainActor
final class SubcorpusValuePickerModel {
    struct Loaders {
        /// Distinct values of a dotted attribute (`doc.genre`), at most
        /// `limit` of them.
        var values: @Sendable (_ attribute: String, _ limit: Int) async throws -> [String]
        /// Values containing `text` (case-insensitive), at most `limit`.
        var search: @Sendable (_ attribute: String, _ text: String, _ limit: Int) async throws -> [String]
    }

    /// The longest list shown. An attribute with more values than this
    /// (`doc.id` in a big corpus) is searched in the engine instead of
    /// filtered here.
    static let listCap = 500

    let info: CorpusInfo
    private let loaders: Loaders

    private(set) var structure: String
    private(set) var attribute: String?
    /// What the list shows now, sorted for reading.
    private(set) var rows: [String] = []
    /// `rows` is only part of the matching values (`listCap` of more).
    private(set) var isTruncated = false
    private(set) var isLoading = false
    private(set) var loadError: String?

    /// Every value of the attribute, when there are few enough to hold; the
    /// search then filters this instead of asking the engine.
    private var complete: [String]?
    private var selected: [String: Set<String>] = [:]
    /// Bumped by every request, so a slow answer to an old question can't
    /// overwrite the answer to the current one.
    private var generation = 0

    init(info: CorpusInfo, loaders: Loaders) {
        self.info = info
        self.loaders = loaders
        structure = info.structures.first?.name ?? ""
        attribute = info.structures.first?.attributes.first
    }

    var structures: [String] { info.structures.map(\.name) }

    var attributes: [String] {
        info.structures.first { $0.name == structure }?.attributes ?? []
    }

    // MARK: Choosing what to list

    /// Switching is immediate (the old list and picks are gone at once, so
    /// the UI can't show a stale list next to new state); loading the new
    /// list is `reload()`, which the caller awaits.
    func selectStructure(_ name: String) {
        guard name != structure, structures.contains(name) else { return }
        structure = name
        selected = [:]
        attribute = attributes.first
        startLoading()
    }

    func selectAttribute(_ name: String) {
        guard name != attribute, attributes.contains(name) else { return }
        attribute = name
        startLoading()
    }

    /// Clears the list and marks it as loading, and invalidates any answer
    /// still on its way for an earlier question.
    private func startLoading() {
        generation += 1
        rows = []
        complete = nil
        isTruncated = false
        loadError = nil
        isLoading = attribute != nil
    }

    /// Loads the current attribute's values from scratch.
    func reload() async {
        startLoading()
        let mine = generation
        guard let dotted = dottedAttribute else { return }
        do {
            let values = try await loaders.values(dotted, Self.listCap + 1)
            guard mine == generation else { return }
            if values.count > Self.listCap {
                isTruncated = true
                rows = Self.sorted(Array(values.prefix(Self.listCap)))
            } else {
                complete = Self.sorted(values)
                rows = complete ?? []
            }
        } catch {
            guard mine == generation else { return }
            loadError = "\(error)"
        }
        isLoading = false
    }

    /// Narrows the list to values containing `text`; empty shows all again.
    func search(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let complete {
            generation += 1
            rows = text.isEmpty ? complete : complete.filter { $0.localizedCaseInsensitiveContains(text) }
            return
        }
        guard let dotted = dottedAttribute else { return }
        if text.isEmpty {
            await reload()
            return
        }
        generation += 1
        let mine = generation
        loadError = nil
        isLoading = true
        do {
            let found = try await loaders.search(dotted, text, Self.listCap + 1)
            guard mine == generation else { return }
            isTruncated = found.count > Self.listCap
            rows = Self.sorted(Array(found.prefix(Self.listCap)))
        } catch {
            guard mine == generation else { return }
            loadError = "\(error)"
        }
        isLoading = false
    }

    private var dottedAttribute: String? {
        guard let attribute else { return nil }
        return "\(structure).\(attribute)"
    }

    private static func sorted(_ values: [String]) -> [String] {
        values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Picking

    func isSelected(_ value: String) -> Bool {
        guard let attribute else { return false }
        return selected[attribute]?.contains(value) == true
    }

    func toggle(_ value: String) {
        guard let attribute else { return }
        if selected[attribute, default: []].remove(value) == nil {
            selected[attribute, default: []].insert(value)
        }
    }

    func clearSelection() {
        selected = [:]
    }

    /// Values ticked across all attributes of the structure.
    var selectedCount: Int {
        selected.values.reduce(0) { $0 + $1.count }
    }

    /// The picks as a restriction, attributes in registry order and values
    /// in reading order so the string is stable.
    var restriction: SubcorpusRestriction {
        SubcorpusRestriction(selections: attributes.compactMap { name in
            guard let values = selected[name], !values.isEmpty else { return nil }
            return .init(attribute: name, values: Self.sorted(Array(values)))
        })
    }
}
