import Cocoa

/// Content of the toolbar's Operations popover - lists every active sort/
/// filter/shuffle/sample with a per-row remove button, for undoing a single
/// step without unwinding everything after it via Cmd-Z. Also folds in bulk
/// line-group clearing (formerly a separate "Clear Groups" toolbar button -
/// merged here since both are fundamentally "review and cancel active
/// operations"). Line groups still appear as one aggregate row, not one per
/// line, since there can be many of them.
final class OperationsPopoverController: NSViewController {
    /// (index into the document's full operations array, display summary).
    var operations: [(index: Int, summary: String)] = [] {
        didSet { if isViewLoaded { rebuildRows() } }
    }
    /// Number of individual line-group assignments currently active, shown
    /// as one aggregate row rather than one per line.
    var lineGroupCount: Int = 0 {
        didSet { if isViewLoaded { rebuildRows() } }
    }
    var onRemove: ((Int) -> Void)?
    var onClearLineGroups: (() -> Void)?

    /// Sentinel `NSButton.tag` marking the line-groups row's remove button,
    /// distinguishing it from a real `operations` index (always >= 0).
    private static let lineGroupsTag = -1

    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No active sort, filter, shuffle, sample, or line groups.")
    private static let width: CGFloat = 320

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 44))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor

        root.addSubview(stack)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            emptyLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            emptyLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        view = root
        rebuildRows()
    }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let isEmpty = operations.isEmpty && lineGroupCount == 0
        emptyLabel.isHidden = !isEmpty
        stack.isHidden = isEmpty

        for (index, summary) in operations {
            let row = makeRow(tag: index, summary: summary)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if lineGroupCount > 0 {
            let summary = "Line group\(lineGroupCount == 1 ? "" : "s") (\(lineGroupCount) line\(lineGroupCount == 1 ? "" : "s") tagged)"
            let row = makeRow(tag: Self.lineGroupsTag, summary: summary)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        view.layoutSubtreeIfNeeded()
        let contentHeight = isEmpty
            ? emptyLabel.fittingSize.height + 24
            : stack.fittingSize.height + 24
        preferredContentSize = NSSize(width: Self.width, height: max(contentHeight, 44))
    }

    private func makeRow(tag: Int, summary: String) -> NSView {
        let row = NSView()
        let label = NSTextField(labelWithString: summary)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove") ?? NSImage(),
            target: self, action: #selector(removeTapped(_:)))
        removeButton.isBordered = false
        removeButton.tag = tag
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(label)
        row.addSubview(removeButton)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -8),
            removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc private func removeTapped(_ sender: NSButton) {
        if sender.tag == Self.lineGroupsTag {
            onClearLineGroups?()
        } else {
            onRemove?(sender.tag)
        }
    }
}
