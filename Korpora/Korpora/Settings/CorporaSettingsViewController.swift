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

/// Lets the user manage corpora imported via `CorpusImporter`: where they're
/// compiled to, which ones exist, and (see `CorpusMemoryResidency`) which
/// should be kept warm in the OS page cache when there's enough free RAM.
final class CorporaSettingsViewController: NSViewController {
    private struct Row {
        let name: String
        let sizeBytes: UInt64
        var keepResident: Bool
    }

    private enum Column: String { case name, size, resident }

    private let directoryPathLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let memoryBar = MemoryBarView()
    private let memoryLabel = NSTextField(labelWithString: "")
    private let minimumFreeField = NSTextField(string: "")

    private var rows: [Row] = []
    private var refreshTimer: Timer?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 420))

        let directoryLabel = NSTextField(labelWithString: "Compiled corpora directory:")
        directoryPathLabel.lineBreakMode = .byTruncatingMiddle
        directoryPathLabel.font = .systemFont(ofSize: 11)
        directoryPathLabel.textColor = .secondaryLabelColor
        let chooseDirectoryButton = NSButton(title: "Choose\u{2026}", target: self, action: #selector(chooseDirectory))

        tableView.headerView = NSTableHeaderView()
        let nameColumn = NSTableColumn(identifier: .init(Column.name.rawValue))
        nameColumn.title = "Name"
        nameColumn.width = 180
        let sizeColumn = NSTableColumn(identifier: .init(Column.size.rawValue))
        sizeColumn.title = "Size"
        sizeColumn.width = 90
        let residentColumn = NSTableColumn(identifier: .init(Column.resident.rawValue))
        residentColumn.title = "Keep in Memory"
        residentColumn.width = 130
        for column in [nameColumn, sizeColumn, residentColumn] {
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let importButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Import")!,
            target: self, action: #selector(importCorpusTapped))
        let removeButton = NSButton(
            image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
            target: self, action: #selector(removeSelectedCorpus))

        let memoryTitle = NSTextField(labelWithString: "Memory:")
        memoryLabel.font = .systemFont(ofSize: 11)
        memoryLabel.textColor = .secondaryLabelColor
        let minimumFreeLabel = NSTextField(labelWithString: "Minimum free after keeping a corpus resident:")
        let minimumFreeSuffix = NSTextField(labelWithString: "GB")
        minimumFreeField.target = self
        minimumFreeField.action = #selector(minimumFreeChanged)

        let views: [NSView] = [
            directoryLabel, directoryPathLabel, chooseDirectoryButton,
            scrollView, importButton, removeButton,
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
            scrollView.heightAnchor.constraint(equalToConstant: 140),

            importButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            importButton.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            removeButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            removeButton.leadingAnchor.constraint(equalTo: importButton.trailingAnchor, constant: 2),

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
            minimumFreeSuffix.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])

        view = root
        preferredContentSize = NSSize(width: 480, height: 420)
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
            self?.tableView.reloadData()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func reloadCorpora() {
        rows = CompiledCorpusStore.availableCorpusNames().map { name in
            let size = CorpusMemoryResidency.directorySize(CompiledCorpusStore.dataDirectory(for: name))
            return Row(name: name, sizeBytes: size, keepResident: CompiledCorpusStore.metadata(for: name).keepResident)
        }
        tableView.reloadData()
        updateMemoryBar()
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

    @objc private func removeSelectedCorpus() {
        let index = tableView.selectedRow
        guard rows.indices.contains(index) else { return }
        try? CompiledCorpusStore.remove(rows[index].name)
        reloadCorpora()
    }

    @objc private func minimumFreeChanged() {
        let gb = UInt64(minimumFreeField.stringValue) ?? 10
        AppSettings.shared.minimumFreeMemoryAfterResidency = gb * 1_000_000_000
        tableView.reloadData()
    }

    @objc private func keepResidentToggled(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let name = rows[sender.tag].name
        let newValue = sender.state == .on
        var metadata = CompiledCorpusStore.metadata(for: name)
        metadata.keepResident = newValue
        try? CompiledCorpusStore.setMetadata(metadata, for: name)
        rows[sender.tag].keepResident = newValue

        let directory = CompiledCorpusStore.dataDirectory(for: name)
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }) else { return nil }
        let corpus = rows[row]
        switch identifier {
        case .name:
            let field = NSTextField(labelWithString: corpus.name)
            field.font = .systemFont(ofSize: 12)
            return field
        case .size:
            let field = NSTextField(labelWithString: ByteCountFormatter().string(fromByteCount: Int64(corpus.sizeBytes)))
            field.font = .systemFont(ofSize: 12)
            return field
        case .resident:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(keepResidentToggled(_:)))
            checkbox.tag = row
            checkbox.state = corpus.keepResident ? .on : .off
            checkbox.isEnabled = corpus.keepResident || CorpusMemoryResidency.canKeepResident(
                sizeBytes: corpus.sizeBytes, currentlyAvailable: CorpusMemoryResidency.availableMemory(),
                minimumFreeAfter: AppSettings.shared.minimumFreeMemoryAfterResidency)
            checkbox.toolTip = checkbox.isEnabled
                ? nil : "Not enough free memory to keep this corpus resident without going under the minimum."
            return checkbox
        }
    }
}
