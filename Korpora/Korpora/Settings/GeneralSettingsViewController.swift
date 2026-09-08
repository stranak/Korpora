import Cocoa

/// Lets the user point the app at their own corpus registry directories,
/// instead of requiring `MANATEE_REGISTRY` to already be set in the
/// environment the app happened to launch from (fine for `swift run`/Xcode,
/// not for a double-clicked `.app`).
final class GeneralSettingsViewController: NSViewController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var directories: [String] = AppSettings.shared.corpusRegistryDirectories

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))

        let label = NSTextField(labelWithString: "Corpus registry directories:")
        let hint = NSTextField(wrappingLabelWithString:
            "Manatee searches these, in order, for corpus registry files - the same "
                + "role as its own MANATEE_REGISTRY variable. Leave empty to use the "
                + "inherited environment as-is.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        tableView.headerView = nil
        tableView.addTableColumn(NSTableColumn(identifier: .init("path")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let addButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
            target: self, action: #selector(addDirectory))
        let removeButton = NSButton(
            image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
            target: self, action: #selector(removeSelectedDirectory))

        for view in [label, hint, scrollView, addButton, removeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        addButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(equalToConstant: 110),

            addButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            addButton.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            removeButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 2),

            hint.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            hint.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])

        view = root
        preferredContentSize = NSSize(width: 420, height: 260)
    }

    @objc private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            directories.append(url.path)
            AppSettings.shared.corpusRegistryDirectories = directories
            tableView.reloadData()
        }
    }

    @objc private func removeSelectedDirectory() {
        let index = tableView.selectedRow
        guard directories.indices.contains(index) else { return }
        directories.remove(at: index)
        AppSettings.shared.corpusRegistryDirectories = directories
        tableView.reloadData()
    }
}

extension GeneralSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { directories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: directories[row])
        field.lineBreakMode = .byTruncatingMiddle
        field.font = .systemFont(ofSize: 12)
        return field
    }
}
