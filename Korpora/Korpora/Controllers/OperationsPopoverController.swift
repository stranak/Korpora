import Cocoa

/// Content of the toolbar's Operations popover - lists every active sort/
/// filter/shuffle/sample with a per-row remove button, for undoing a single
/// step without unwinding everything after it via Cmd-Z. Also folds in
/// line-group clearing (formerly a separate "Clear Groups" toolbar button -
/// merged here since both are fundamentally "review and cancel active
/// operations"), one row per active group so a single group can be cleared
/// without touching the others.
final class OperationsPopoverController: NSViewController {
    /// (index into the document's full operations array, display summary).
    var operations: [(index: Int, summary: String)] = [] {
        didSet { if isViewLoaded { rebuildRows() } }
    }
    /// (group number, number of lines currently tagged with it) - one row
    /// per active group, sorted by group number. Group 0 ("None") is never
    /// included; there's nothing meaningful to clear about it.
    var lineGroups: [(group: Int, lineCount: Int)] = [] {
        didSet { if isViewLoaded { rebuildRows() } }
    }
    var onRemove: ((Int) -> Void)?
    var onClearLineGroup: ((Int) -> Void)?

    /// A line-group row's `NSButton.tag` is encoded as `-(group + 1)` so it
    /// can't collide with a real `operations` index (always >= 0).
    private static func tag(forGroup group: Int) -> Int { -(group + 1) }
    private static func group(fromTag tag: Int) -> Int { -(tag + 1) }

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
        let isEmpty = operations.isEmpty && lineGroups.isEmpty
        emptyLabel.isHidden = !isEmpty
        stack.isHidden = isEmpty

        for (index, summary) in operations {
            let row = makeRow(tag: index, summary: summary)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for (group, lineCount) in lineGroups {
            let summary = "Group \(group) (\(lineCount) line\(lineCount == 1 ? "" : "s"))"
            let row = makeRow(tag: Self.tag(forGroup: group), summary: summary)
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
        if sender.tag < 0 {
            onClearLineGroup?(Self.group(fromTag: sender.tag))
        } else {
            onRemove?(sender.tag)
        }
    }
}
