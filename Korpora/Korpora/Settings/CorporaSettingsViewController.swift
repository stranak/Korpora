import Cocoa
import ManateeKit

/// A small horizontal gauge - total vs. currently-available memory - no
/// charting library needed for something this simple.
private final class MemoryBarView: NSView {
    private let usedView = NSView()
    private var usedWidthConstraint: NSLayoutConstraint!
    private var lastFraction: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = 4

        usedView.wantsLayer = true
        usedView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        usedView.layer?.cornerRadius = 4
        usedView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(usedView)
        usedWidthConstraint = usedView.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            usedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            usedView.topAnchor.constraint(equalTo: topAnchor),
            usedView.bottomAnchor.constraint(equalTo: bottomAnchor),
            usedWidthConstraint,
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setUsedFraction(_ fraction: Double) {
        lastFraction = max(0, min(1, fraction))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        usedWidthConstraint.constant = bounds.width * CGFloat(lastFraction)
    }
}

/// Every corpus the app can open, in one list (docs/project-plan.md,
/// "Corpus Settings UX"): the ones Korpora built from a vertical file, the
/// ones compiled elsewhere and added here, and any inherited from the
/// environment. They differ only in who compiled them and wrote the
/// registry file, so they're listed, removed and kept in memory (see
/// `CorpusMemoryResidency`) the same way.
final class CorporaSettingsViewController: NSViewController {
    private struct Row {
        let entry: CorpusLibrary.Entry
        let sizeBytes: UInt64
        var keepResident: Bool

        var name: String { entry.name }
    }

    private enum Column: String { case name, source, size, resident }

    private let directoryPathLabel = NSTextField(labelWithString: "")
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let memoryBar = MemoryBarView()
    private let memoryLabel = NSTextField(labelWithString: "")
    private let minimumFreeField = NSTextField(string: "")
    private let removeButton = NSButton(
        image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
        target: nil, action: nil)

    private var rows: [Row] = []
    private var refreshTimer: Timer?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 440))
        // Follow the window when it's resized; without this Auto Layout pins the
        // view to the size it was created with.
        root.autoresizingMask = [.width, .height]

        let directoryLabel = NSTextField(labelWithString: "Corpora built by Korpora are stored in:")
        directoryPathLabel.lineBreakMode = .byTruncatingMiddle
        directoryPathLabel.font = .systemFont(ofSize: 11)
        directoryPathLabel.textColor = .secondaryLabelColor
        let chooseDirectoryButton = NSButton(title: "Choose\u{2026}", target: self, action: #selector(chooseDirectory))

        tableView.headerView = NSTableHeaderView()
        let nameColumn = NSTableColumn(identifier: .init(Column.name.rawValue))
        nameColumn.title = "Name"
        nameColumn.width = 160
        let sourceColumn = NSTableColumn(identifier: .init(Column.source.rawValue))
        sourceColumn.title = "Source"
        sourceColumn.width = 120
        let sizeColumn = NSTableColumn(identifier: .init(Column.size.rawValue))
        sizeColumn.title = "Size"
        sizeColumn.width = 80
        let residentColumn = NSTableColumn(identifier: .init(Column.resident.rawValue))
        residentColumn.title = "Keep in Memory"
        residentColumn.width = 120
        for column in [nameColumn, sourceColumn, sizeColumn, residentColumn] {
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let importButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
            target: self, action: #selector(showAddMenu(_:)))
        removeButton.target = self
        removeButton.action = #selector(removeSelectedCorpus)
        removeButton.isEnabled = false
        let addHint = NSTextField(labelWithString:
            "+ imports a vertical file, or adds a corpus compiled elsewhere.")
        addHint.font = .systemFont(ofSize: 11)
        addHint.textColor = .secondaryLabelColor

        let memoryTitle = NSTextField(labelWithString: "Memory:")
        memoryLabel.font = .systemFont(ofSize: 11)
        memoryLabel.textColor = .secondaryLabelColor
        let minimumFreeLabel = NSTextField(labelWithString: "Minimum free after keeping a corpus resident:")
        let minimumFreeSuffix = NSTextField(labelWithString: "GB")
        minimumFreeField.target = self
        minimumFreeField.action = #selector(minimumFreeChanged)

        let views: [NSView] = [
            directoryLabel, directoryPathLabel, chooseDirectoryButton,
            scrollView, importButton, removeButton, addHint,
            memoryTitle, memoryBar, memoryLabel,
            minimumFreeLabel, minimumFreeField, minimumFreeSuffix,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        importButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        minimumFreeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        memoryBar.heightAnchor.constraint(equalToConstant: 12).isActive = true

        NSLayoutConstraint.activate([
            directoryLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            directoryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            chooseDirectoryButton.centerYAnchor.constraint(equalTo: directoryLabel.centerYAnchor),
            chooseDirectoryButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            directoryPathLabel.topAnchor.constraint(equalTo: directoryLabel.bottomAnchor, constant: 4),
            directoryPathLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            directoryPathLabel.trailingAnchor.constraint(equalTo: chooseDirectoryButton.leadingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: directoryPathLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            // At least 140 tall, and the pane's spare height when the window is
            // resized: the list is the one thing that benefits from more room.
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),

            importButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            importButton.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            removeButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            removeButton.leadingAnchor.constraint(equalTo: importButton.trailingAnchor, constant: 2),

            addHint.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
            addHint.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 10),
            addHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            memoryTitle.topAnchor.constraint(equalTo: importButton.bottomAnchor, constant: 20),
            memoryTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            memoryBar.centerYAnchor.constraint(equalTo: memoryTitle.centerYAnchor),
            memoryBar.leadingAnchor.constraint(equalTo: memoryTitle.trailingAnchor, constant: 8),
            memoryBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            memoryLabel.topAnchor.constraint(equalTo: memoryBar.bottomAnchor, constant: 4),
            memoryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            memoryLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            minimumFreeLabel.topAnchor.constraint(equalTo: memoryLabel.bottomAnchor, constant: 16),
            minimumFreeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            minimumFreeField.centerYAnchor.constraint(equalTo: minimumFreeLabel.centerYAnchor),
            minimumFreeField.leadingAnchor.constraint(equalTo: minimumFreeLabel.trailingAnchor, constant: 8),
            minimumFreeSuffix.centerYAnchor.constraint(equalTo: minimumFreeLabel.centerYAnchor),
            minimumFreeSuffix.leadingAnchor.constraint(equalTo: minimumFreeField.trailingAnchor, constant: 4),
            minimumFreeSuffix.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = root
        preferredContentSize = NSSize(width: 540, height: 440)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        directoryPathLabel.stringValue = AppSettings.shared.compiledCorporaDirectory
            ?? CompiledCorpusStore.baseDirectory.path
        minimumFreeField.stringValue = String(AppSettings.shared.minimumFreeMemoryAfterResidency / 1_000_000_000)
        reloadCorpora()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateMemoryBar()
            self?.refreshMemoryDependentColumn()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Rebuilds the list. The selection follows the corpus, not the row
    /// number, so adding or removing another corpus doesn't move it.
    func reloadCorpora() {
        let selectedName = selectedCorpusName
        rows = AppSettings.shared.corpusLibraryEntries()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { entry in
                Row(entry: entry,
                    sizeBytes: entry.dataDirectory.map(CorpusMemoryResidency.directorySize) ?? 0,
                    keepResident: AppSettings.shared.isKeepResident(entry.name))
            }
        tableView.reloadData()
        if let selectedName, let row = rows.firstIndex(where: { $0.name == selectedName }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateRemoveButton()
        updateMemoryBar()
    }

    var selectedCorpusName: String? {
        rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow].name : nil
    }

    /// Whether a corpus still fits in free memory changes as memory does, so
    /// the "Keep in Memory" checkboxes are refreshed on a timer. Only that
    /// column: `reloadData()` would clear the selection, and with it the
    /// chance to click "\u{2212}" (found in the macOS 15 smoke test of 0.2).
    func refreshMemoryDependentColumn() {
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.resident.rawValue))
        guard column >= 0, !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count),
                             columnIndexes: IndexSet(integer: column))
    }

    private func updateMemoryBar() {
        let total = CorpusMemoryResidency.totalMemory
        let available = CorpusMemoryResidency.availableMemory()
        guard total > 0 else { return }
        memoryBar.setUsedFraction(1 - Double(available) / Double(total))
        let formatter = ByteCountFormatter()
        memoryLabel.stringValue =
            "\(formatter.string(fromByteCount: Int64(available))) available of \(formatter.string(fromByteCount: Int64(total)))"
    }

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            AppSettings.shared.compiledCorporaDirectory = url.path
            directoryPathLabel.stringValue = url.path
            reloadCorpora()
        }
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("Import Vertical File\u{2026}", #selector(importCorpusTapped)),
                                ("Add Existing Corpus\u{2026}", #selector(addExistingCorpusTapped))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func importCorpusTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let sheet = CorpusImportSheetController(verticalFile: url)
            sheet.onImported = { [weak self] in self?.reloadCorpora() }
            presentAsSheet(sheet)
        }
    }

    /// A corpus compiled elsewhere (`encodevert`, a NoSketch or KonText
    /// installation): pick its registry file, or a folder of them. Korpora
    /// links to the files; nothing is copied.
    @objc private func addExistingCorpusTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a corpus registry file, or a folder of them."
        panel.prompt = "Add"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            addCorpora(at: panel.urls)
        }
    }

    private func addCorpora(at urls: [URL]) {
        var taken = Set(AppSettings.shared.corpusLibraryEntries().map(\.name))
        var problems: [String] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let result = CorpusLibrary.addAll(inDirectory: url, taken: taken)
                taken.formUnion(result.added.map(\.name))
                // Other files in a folder (a README) aren't worth a complaint.
                problems += result.skipped.compactMap { skipped in
                    if case .nameTaken = skipped.reason { return "\(skipped.name): \(skipped.reason)" }
                    return nil
                }
                if result.added.isEmpty && problems.isEmpty {
                    problems.append("\u{201C}\(url.lastPathComponent)\u{201D} has no corpus registry files.")
                }
            } else {
                do {
                    taken.insert(try CorpusLibrary.add(registryFile: url, taken: taken).name)
                } catch {
                    problems.append("\(error)")
                }
            }
        }
        reloadCorpora()
        if !problems.isEmpty, let window = view.window {
            let alert = NSAlert()
            alert.messageText = "Some corpora weren\u{2019}t added"
            alert.informativeText = problems.joined(separator: "\n")
            alert.beginSheetModal(for: window)
        }
    }

    private func updateRemoveButton() {
        let index = tableView.selectedRow
        removeButton.isEnabled = rows.indices.contains(index) && rows[index].entry.isRemovable
    }

    /// Both kinds of corpus are removed the same way: the user chooses
    /// whether the data goes too.
    @objc private func removeSelectedCorpus() {
        let index = tableView.selectedRow
        guard rows.indices.contains(index), rows[index].entry.isRemovable, let window = view.window else { return }
        let row = rows[index]
        let size = ByteCountFormatter().string(fromByteCount: Int64(row.sizeBytes))
        let alert = NSAlert()
        alert.messageText = "Remove \u{201C}\(row.name)\u{201D}?"
        var text: String
        switch row.entry.origin {
        case .built:
            text = "Korpora built this corpus. Its data (\(size)) is in "
                + "\(row.entry.dataDirectory?.path ?? "the compiled corpora directory"). "
                + "Keeping the data moves it to the \u{201C}Removed\u{201D} folder there; "
                + "add it back later with Add Existing Corpus\u{2026}."
        case .added(let registryFile):
            text = "This corpus was compiled outside Korpora (registry file \(registryFile.path), "
                + "data \(size)). Keeping the data only takes it off this list; the files stay where they are."
        case .environment:
            return
        }
        alert.informativeText = text + " Deleting the data can\u{2019}t be undone."
        alert.addButton(withTitle: "Remove, Keep Data")
        let deleteButton = alert.addButton(withTitle: "Remove and Delete Data")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.remove(row, deleteData: false)
            case .alertSecondButtonReturn: self?.remove(row, deleteData: true)
            default: break
            }
        }
    }

    private func remove(_ row: Row, deleteData: Bool) {
        // Release the warmed pages first: a kept built corpus moves, and a
        // deleted one is gone.
        if AppSettings.shared.isKeepResident(row.name) {
            AppSettings.shared.setKeepResident(false, for: row.name)
            if let directory = row.entry.dataDirectory { CorpusMemoryResidency.unwarm(directory: directory) }
        }
        let entry = row.entry
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure: Error?
            do {
                try CorpusLibrary.remove(entry, deleteData: deleteData)
                failure = nil
            } catch {
                failure = error
            }
            await MainActor.run {
                guard let self else { return }
                self.reloadCorpora()
                if let failure, let window = self.view.window {
                    let alert = NSAlert(error: failure)
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    @objc private func minimumFreeChanged() {
        let gb = UInt64(minimumFreeField.stringValue) ?? 10
        AppSettings.shared.minimumFreeMemoryAfterResidency = gb * 1_000_000_000
        refreshMemoryDependentColumn()
    }

    @objc private func keepResidentToggled(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), let directory = rows[sender.tag].entry.dataDirectory else { return }
        let newValue = sender.state == .on
        AppSettings.shared.setKeepResident(newValue, for: rows[sender.tag].name)
        rows[sender.tag].keepResident = newValue

        Task.detached(priority: .utility) {
            if newValue {
                try? await CorpusMemoryResidency.warm(directory: directory)
            } else {
                CorpusMemoryResidency.unwarm(directory: directory)
            }
        }
    }
}

extension CorporaSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    static func sourceTitle(_ origin: CorpusLibrary.Origin) -> String {
        switch origin {
        case .built: return "Built by Korpora"
        case .added: return "Added"
        case .environment: return "Environment"
        }
    }

    static func sourceDetail(_ origin: CorpusLibrary.Origin) -> String {
        switch origin {
        case .built: return "Compiled by Korpora from a vertical file."
        case .added(let file): return "Compiled elsewhere; registry file \(file.path)"
        case .environment(let dir):
            return "Found through MANATEE_REGISTRY (\(dir.path)); Korpora can\u{2019}t remove it."
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }) else { return nil }
        let corpus = rows[row]
        switch identifier {
        case .name:
            let field = NSTextField(labelWithString: corpus.name)
            field.font = .systemFont(ofSize: 12)
            return field
        case .source:
            let field = NSTextField(labelWithString: Self.sourceTitle(corpus.entry.origin))
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.toolTip = Self.sourceDetail(corpus.entry.origin)
            return field
        case .size:
            let field = NSTextField(labelWithString: ByteCountFormatter().string(fromByteCount: Int64(corpus.sizeBytes)))
            field.font = .systemFont(ofSize: 12)
            return field
        case .resident:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(keepResidentToggled(_:)))
            checkbox.tag = row
            checkbox.state = corpus.keepResident ? .on : .off
            let fits = CorpusMemoryResidency.canKeepResident(
                sizeBytes: corpus.sizeBytes, currentlyAvailable: CorpusMemoryResidency.availableMemory(),
                minimumFreeAfter: AppSettings.shared.minimumFreeMemoryAfterResidency)
            checkbox.isEnabled = corpus.entry.dataDirectory != nil && (corpus.keepResident || fits)
            checkbox.toolTip = corpus.entry.dataDirectory == nil
                ? "This corpus's registry file has no readable PATH."
                : (checkbox.isEnabled
                    ? nil : "Not enough free memory to keep this corpus resident without going under the minimum.")
            return checkbox
        }
    }
}
