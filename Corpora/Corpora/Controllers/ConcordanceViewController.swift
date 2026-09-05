import Cocoa
import ManateeKit

final class ConcordanceViewController: NSViewController {
    private enum Section { case main }
    private enum Column: String { case group, left, kwic, right }

    private let document: ConcordanceDocument
    private let queryField = CQLQueryField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var dataSource: NSTableViewDiffableDataSource<Section, Int>!

    weak var windowController: ConcordanceWindowController?

    init(document: ConcordanceDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 520))

        queryField.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        root.addSubview(queryField)
        root.addSubview(statusLabel)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            queryField.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            queryField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            queryField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),

            statusLabel.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpTableView()
        setUpContextMenu()

        queryField.text = document.initialQuery
        queryField.onSubmit = { [weak self] in self?.runQuery() }

        document.onResultsChanged = { [weak self] in self?.refresh() }
        refresh()

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange), name: AppSettings.didChangeNotification, object: nil)
    }

    /// A font-setting change doesn't touch `document.rows`, so the diffable
    /// data source (keyed on row `id`, not content) wouldn't otherwise know
    /// to redraw anything - force every visible cell to rebuild.
    @objc private func settingsDidChange() {
        tableView.reloadData()
    }

    private func runQuery() {
        document.runQuery(queryField.text)
    }

    // MARK: - Toolbar actions

    @objc func sortTapped(_ sender: NSButton) {
        let popover = NSPopover()
        let controller = SortPopoverController()
        controller.onApply = { [weak self, weak popover] criteria in
            self?.document.performSort(criteria)
            popover?.close()
        }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc func filterTapped(_ sender: Any) {
        let sheet = FilterSheetController()
        sheet.onApply = { [weak self] spec in
            self?.document.performFilter(spec)
        }
        presentAsSheet(sheet)
    }

    @objc func shuffleTapped(_ sender: Any) {
        document.performShuffle()
    }

    @objc func sampleTapped(_ sender: NSButton) {
        let popover = NSPopover()
        let controller = SamplePopoverController()
        controller.onApply = { [weak self, weak popover] lines in
            self?.document.performSample(lines: lines)
            popover?.close()
        }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc func clearGroupsTapped(_ sender: Any) {
        document.performClearLineGroups()
    }

    // MARK: - Table view

    private func setUpTableView() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .plain
        tableView.headerView = NSTableHeaderView()

        let group = NSTableColumn(identifier: .init(Column.group.rawValue))
        group.title = ""
        group.width = 32
        group.minWidth = 32
        group.maxWidth = 32
        group.resizingMask = []

        let left = NSTableColumn(identifier: .init(Column.left.rawValue))
        left.title = "Left"
        left.resizingMask = .userResizingMask
        left.width = 270

        let kwic = NSTableColumn(identifier: .init(Column.kwic.rawValue))
        kwic.title = "Match"
        kwic.resizingMask = .userResizingMask
        kwic.width = 160

        let right = NSTableColumn(identifier: .init(Column.right.rawValue))
        right.title = "Right"
        right.resizingMask = .autoresizingMask
        right.width = 270

        tableView.addTableColumn(group)
        tableView.addTableColumn(left)
        tableView.addTableColumn(kwic)
        tableView.addTableColumn(right)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        dataSource = NSTableViewDiffableDataSource<Section, Int>(tableView: tableView) { [weak self] _, column, _, id in
            self?.makeCell(for: column, rowID: id) ?? NSView()
        }
        tableView.dataSource = dataSource

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
    }

    private func makeCell(for column: NSTableColumn?, rowID: Int) -> NSView {
        guard document.rows.indices.contains(rowID) else { return NSView() }
        let row = document.rows[rowID]
        let cell = KWICCellView()
        switch column.flatMap({ Column(rawValue: $0.identifier.rawValue) }) {
        case .group:
            cell.configureGroup(row.group)
        case .left:
            cell.configure(text: row.line.left, alignment: .right, style: .plain)
        case .kwic:
            cell.configure(text: row.line.kwic, alignment: .center, style: .highlighted)
        case .right:
            cell.configure(text: row.line.right, alignment: .left, style: .plain)
        case nil:
            break
        }
        return cell
    }

    private func refresh() {
        if queryField.text != document.initialQuery {
            queryField.text = document.initialQuery
        }
        statusLabel.stringValue = document.status
        var snapshot = NSDiffableDataSourceSnapshot<Section, Int>()
        snapshot.appendSections([.main])
        let ids = document.rows.map(\.id)
        snapshot.appendItems(ids)
        // A row's `id` is a stable offset, not a content hash - e.g. a
        // line-group assignment changes `group` without changing `id`, so
        // without an explicit reload the diffable data source would decide
        // nothing changed and leave the (now stale) cell alone.
        snapshot.reloadItems(ids)
        dataSource.apply(snapshot, animatingDifferences: true)
        windowController?.updateToolbarState(hasLineGroups: document.hasLineGroups)
    }

    // MARK: - Row context menu

    private func setUpContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
    }

    private func targetedRows() -> IndexSet {
        let clicked = tableView.clickedRow
        guard clicked >= 0 else { return [] }
        return tableView.selectedRowIndexes.contains(clicked) ? tableView.selectedRowIndexes : [clicked]
    }

    @objc private func assignLineGroup(_ sender: NSMenuItem) {
        // Each selected row becomes its own single-line operation - simple
        // and correct, if not as compact an undo chain as a batched op would be.
        for row in targetedRows() {
            document.performSetLineGroup(rangeStart: row, rangeLen: 1, group: sender.tag)
        }
    }

    @objc private func filterToSelection(_ sender: Any) {
        let row = tableView.clickedRow
        guard document.rows.indices.contains(row) else { return }
        let word = document.rows[row].line.kwic.components(separatedBy: .whitespaces).first { !$0.isEmpty } ?? ""
        guard !word.isEmpty else { return }
        document.performFilter(PNFilterSpec(positive: true, leftOffset: 0, rightOffset: 1, query: #"[word="\#(word)"]"#))
    }

    @objc private func copySelection(_ sender: Any) {
        let row = tableView.clickedRow
        guard document.rows.indices.contains(row) else { return }
        let line = document.rows[row].line
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(line.left)\t\(line.kwic)\t\(line.right)", forType: .string)
    }
}

extension ConcordanceViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard tableView.clickedRow >= 0 else { return }

        let groupSubmenu = NSMenu()
        for number in 1...9 {
            let item = NSMenuItem(title: "Group \(number)", action: #selector(assignLineGroup(_:)), keyEquivalent: "")
            item.tag = number
            item.target = self
            groupSubmenu.addItem(item)
        }
        groupSubmenu.addItem(.separator())
        let noneItem = NSMenuItem(title: "None", action: #selector(assignLineGroup(_:)), keyEquivalent: "")
        noneItem.tag = 0
        noneItem.target = self
        groupSubmenu.addItem(noneItem)

        let groupItem = NSMenuItem(title: "Assign to Line Group", action: nil, keyEquivalent: "")
        groupItem.submenu = groupSubmenu
        menu.addItem(groupItem)

        menu.addItem(.separator())
        let filterItem = NSMenuItem(title: "Filter to Selection", action: #selector(filterToSelection(_:)), keyEquivalent: "")
        filterItem.target = self
        menu.addItem(filterItem)
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
    }
}
