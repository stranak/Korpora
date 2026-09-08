import Cocoa

/// Content of the toolbar's History popover - the most recent queries run,
/// any corpus, most-recent-first (see `QueryHistoryStore`). Click a row to
/// re-run it in the current window.
final class HistoryPopoverController: NSViewController {
    var entries: [QueryHistoryEntry] = [] {
        didSet { if isViewLoaded { rebuildRows() } }
    }
    var onSelect: ((QueryHistoryEntry) -> Void)?
    var onClear: (() -> Void)?

    /// Only the most recent entries are shown - this is a quick-recall list,
    /// not a searchable archive; `QueryHistoryStore` itself keeps far more
    /// (`QueryHistoryStore.maxEntries`) so a long session's earlier queries
    /// aren't lost, just not all listed here at once.
    private static let displayLimit = 20
    private static let width: CGFloat = 360

    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No queries run yet.")
    private let clearButton = NSButton(title: "Clear History", target: nil, action: nil)

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 44))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        root.addSubview(stack)
        root.addSubview(emptyLabel)
        root.addSubview(clearButton)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            emptyLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            clearButton.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            clearButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            clearButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        view = root
        rebuildRows()
    }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shown = Array(entries.prefix(Self.displayLimit))
        let isEmpty = shown.isEmpty
        emptyLabel.isHidden = !isEmpty
        stack.isHidden = isEmpty
        clearButton.isHidden = entries.isEmpty

        for (index, entry) in shown.enumerated() {
            let row = makeRow(tag: index, entry: entry)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        view.layoutSubtreeIfNeeded()
        let listHeight = isEmpty ? emptyLabel.fittingSize.height : stack.fittingSize.height
        preferredContentSize = NSSize(width: Self.width, height: listHeight + clearButton.fittingSize.height + 36)
    }

    private func makeRow(tag: Int, entry: QueryHistoryEntry) -> NSButton {
        let corpusLabel = entry.subcorpusPath != nil ? "\(entry.corpusName) (subcorpus)" : entry.corpusName
        let relative = Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date())
        // Manually truncated (rather than relying on button-cell wrapping/
        // truncation behavior) to match this codebase's existing preference
        // for explicit, predictable string bounds - see e.g.
        // `CorpusImportSheetController.showFormError`.
        let query = entry.query.count > 60 ? String(entry.query.prefix(60)) + "…" : entry.query
        let button = NSButton(title: "\(corpusLabel): \(query)  (\(relative))",
                               target: self, action: #selector(rowTapped(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.tag = tag
        button.alignment = .left
        button.font = .systemFont(ofSize: 12)
        button.toolTip = "\(entry.corpusName)\n\(entry.query)"
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func rowTapped(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        onSelect?(entries[sender.tag])
    }

    @objc private func clearTapped() {
        onClear?()
    }
}
