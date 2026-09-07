import Cocoa
import ManateeKit

/// The sheet a brand-new `ConcordanceDocument` presents immediately on
/// creation, since it has nothing to show until a corpus + CQL query are known.
///
/// The corpus picker only ever lists corpora that already exist in the
/// Manatee registry - opening one, never creating one. "New Concordance"
/// means a new query/result document, not a new corpus. A subcorpus,
/// though, genuinely can be created here (see `NewSubcorpusPopoverController`).
final class NewConcordanceSheetController: NSViewController {
    private enum SubcorpusItem {
        static let whole = "Whole Corpus"
        static let newOne = "New Subcorpus…"
    }

    var corpusName: String = ""
    var query: String = ""
    /// (corpus name, subcorpus path or nil for the whole corpus, CQL query)
    var onCommit: ((String, String?, String) -> Void)?
    var onCancel: (() -> Void)?

    private let corpusPopUp = NSPopUpButton()
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private let subcorpusPopUp = NSPopUpButton()
    private let queryField = CQLQueryField()
    private var searchButton: NSButton!
    private var currentCorpusInfo: CorpusInfo?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))

        let title = NSTextField(labelWithString: "New Concordance")
        title.font = .boldSystemFont(ofSize: 13)

        let corpusLabel = NSTextField(labelWithString: "Corpus:")
        let availableCorpora = CorpusRegistry.availableCorpusNames()
        if availableCorpora.isEmpty {
            corpusPopUp.addItem(withTitle: "No corpora found")
            corpusPopUp.isEnabled = false
        } else {
            corpusPopUp.addItems(withTitles: availableCorpora)
            if !corpusName.isEmpty {
                corpusPopUp.selectItem(withTitle: corpusName)
            }
        }
        corpusPopUp.target = self
        corpusPopUp.action = #selector(corpusSelectionChanged)

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor

        let subcorpusLabel = NSTextField(labelWithString: "Subcorpus:")
        subcorpusPopUp.target = self
        subcorpusPopUp.action = #selector(subcorpusSelectionChanged)

        let queryLabel = NSTextField(labelWithString: "Query (CQL):")
        queryField.text = query
        queryField.onSubmit = { [weak self] in self?.searchTapped() }

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.keyEquivalent = "\u{1b}"

        searchButton = NSButton(title: "Search", target: self, action: #selector(searchTapped))
        searchButton.keyEquivalent = "\r"
        searchButton.bezelStyle = .rounded
        searchButton.isEnabled = !availableCorpora.isEmpty

        let views: [NSView] = [
            title, corpusLabel, corpusPopUp, infoLabel, subcorpusLabel, subcorpusPopUp,
            queryLabel, queryField, cancelButton, searchButton,
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            corpusLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            corpusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            corpusPopUp.centerYAnchor.constraint(equalTo: corpusLabel.centerYAnchor),
            corpusPopUp.leadingAnchor.constraint(equalTo: corpusLabel.trailingAnchor, constant: 8),

            infoLabel.topAnchor.constraint(equalTo: corpusLabel.bottomAnchor, constant: 6),
            infoLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            subcorpusLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 12),
            subcorpusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            subcorpusPopUp.centerYAnchor.constraint(equalTo: subcorpusLabel.centerYAnchor),
            subcorpusPopUp.leadingAnchor.constraint(equalTo: subcorpusLabel.trailingAnchor, constant: 8),

            queryLabel.topAnchor.constraint(equalTo: subcorpusLabel.bottomAnchor, constant: 16),
            queryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            queryField.topAnchor.constraint(equalTo: queryLabel.bottomAnchor, constant: 6),
            queryField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            queryField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            searchButton.topAnchor.constraint(greaterThanOrEqualTo: queryField.bottomAnchor, constant: 16),
            searchButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            cancelButton.centerYAnchor.constraint(equalTo: searchButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -8),
        ])

        // Explicit, not relying on AppKit's auto-generated Tab loop:
        // `queryField` is a custom composite view (NSScrollView + a nested
        // NSTextView, not a standard control), which that heuristic loop
        // doesn't reliably reach into - without this, Tabbing from
        // `subcorpusPopUp` skipped straight past the query field to the
        // buttons (found via manual testing, 2026-09-07).
        corpusPopUp.nextKeyView = subcorpusPopUp
        subcorpusPopUp.nextKeyView = queryField.textView
        queryField.textView.nextKeyView = searchButton
        searchButton.nextKeyView = cancelButton

        view = root
        preferredContentSize = NSSize(width: 480, height: 300)

        refreshForSelectedCorpus()
    }

    /// Nothing focuses `queryField` just because the sheet is on screen -
    /// same root cause as the Tab-loop gap above, a custom composite view
    /// isn't what AppKit's initial-first-responder heuristics expect
    /// either. `viewDidAppear` (not `loadView`) is the first point the view
    /// is guaranteed to actually have a window to focus within.
    override func viewDidAppear() {
        super.viewDidAppear()
        queryField.focus()
    }

    private func refreshForSelectedCorpus() {
        guard let name = corpusPopUp.titleOfSelectedItem, corpusPopUp.isEnabled else {
            infoLabel.stringValue = ""
            subcorpusPopUp.removeAllItems()
            currentCorpusInfo = nil
            return
        }
        reloadSubcorpusList(for: name)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let corpus = try Corpus(name: name)
                let info = await corpus.info()
                currentCorpusInfo = info
                var parts: [String] = []
                if !info.attributes.isEmpty {
                    parts.append("Attributes: " + info.attributes.joined(separator: ", "))
                }
                if !info.structures.isEmpty {
                    let structs = info.structures.map { s in
                        s.attributes.isEmpty ? s.name : "\(s.name) (\(s.attributes.joined(separator: ", ")))"
                    }
                    parts.append("Structures: " + structs.joined(separator: ", "))
                }
                infoLabel.stringValue = parts.joined(separator: "\n")
            } catch {
                currentCorpusInfo = nil
                infoLabel.stringValue = "\(error)"
            }
        }
    }

    private func reloadSubcorpusList(for corpusName: String) {
        subcorpusPopUp.removeAllItems()
        subcorpusPopUp.addItem(withTitle: SubcorpusItem.whole)
        let existing = SubcorpusStore.availableSubcorpora(for: corpusName)
        if !existing.isEmpty {
            subcorpusPopUp.menu?.addItem(.separator())
            subcorpusPopUp.addItems(withTitles: existing)
        }
        subcorpusPopUp.menu?.addItem(.separator())
        subcorpusPopUp.addItem(withTitle: SubcorpusItem.newOne)
    }

    @objc private func corpusSelectionChanged() {
        refreshForSelectedCorpus()
    }

    @objc private func subcorpusSelectionChanged() {
        guard subcorpusPopUp.titleOfSelectedItem == SubcorpusItem.newOne,
              let corpusName = corpusPopUp.titleOfSelectedItem else { return }
        // Reset immediately - becomes the new subcorpus's name on success,
        // rather than staying stuck on "New Subcorpus…" if the popover is
        // dismissed without creating one.
        subcorpusPopUp.selectItem(withTitle: SubcorpusItem.whole)

        let popover = NSPopover()
        let controller = NewSubcorpusPopoverController()
        controller.corpusInfo = currentCorpusInfo
        controller.onCreate = { [weak self, weak popover] name, structure, query in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let corpus = try Corpus(name: corpusName)
                    _ = try await corpus.createSubcorpus(named: name, structure: structure, query: query)
                    self.reloadSubcorpusList(for: corpusName)
                    self.subcorpusPopUp.selectItem(withTitle: name)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t Create Subcorpus"
                    alert.informativeText = "\(error)"
                    alert.runModal()
                }
                popover?.close()
            }
        }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: subcorpusPopUp.bounds, of: subcorpusPopUp, preferredEdge: .maxY)
    }

    @objc private func searchTapped() {
        guard let corpus = corpusPopUp.titleOfSelectedItem, corpusPopUp.isEnabled else { return }
        var subcorpusPath: String?
        if let selected = subcorpusPopUp.titleOfSelectedItem,
           selected != SubcorpusItem.whole, selected != SubcorpusItem.newOne {
            subcorpusPath = SubcorpusStore.path(for: corpus, subcorpusName: selected)
        }
        onCommit?(corpus, subcorpusPath, queryField.text)
        dismiss(self)
    }

    @objc private func cancelTapped() {
        onCancel?()
        dismiss(self)
    }
}
