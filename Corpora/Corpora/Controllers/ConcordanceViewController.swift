import Cocoa
import ManateeKit

final class ConcordanceViewController: NSViewController {
    private enum Section { case main }
    private enum Column: String { case group, left, kwic, right }

    private let document: ConcordanceDocument
    private let queryField = CQLQueryField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = SortableTableView()
    private let scrollView = NSScrollView()
    private var dataSource: NSTableViewDiffableDataSource<Section, Int>!
    // Guards against `syncSortIndicators` (which assigns `tableView.
    // sortDescriptors` to mirror the document's actual current sort) being
    // mistaken for a user header click and re-applied as a new operation.
    private var isSyncingSortIndicators = false
    // The Operations popover, while open, needs to be kept in sync with
    // `refresh()` - see its use in `refresh()` for why.
    private weak var activeOperationsPopover: OperationsPopoverController?
    // Collocation/frequency results windows are plain NSWindowControllers,
    // not NSDocuments (see docs/project-plan.md's Phase 3 writeup) - nothing
    // else keeps them alive while shown, so this array does. Entries remove
    // themselves on close (see `show(_:)` below).
    private var auxiliaryWindowControllers: [NSWindowController] = []

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

    @objc func operationsTapped(_ sender: NSButton) {
        let popover = NSPopover()
        let controller = OperationsPopoverController()
        updateOperationsPopover(controller)
        activeOperationsPopover = controller
        controller.onRemove = { [weak self, weak controller] index in
            guard let self, let controller else { return }
            document.removeOperation(at: index)
            updateOperationsPopover(controller)
        }
        controller.onClearLineGroup = { [weak self, weak controller] group in
            guard let self, let controller else { return }
            document.performClearLineGroup(group)
            updateOperationsPopover(controller)
        }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func updateOperationsPopover(_ controller: OperationsPopoverController) {
        controller.operations = document.operations.enumerated()
            .filter { !$0.element.isLineGroupOperation }
            .map { (index: $0.offset, summary: $0.element.summary) }
        // Sourced from the concordance's current per-row group, not raw
        // operation counts, so a line reassigned between groups is only
        // ever counted under its actual current group.
        let counts = Dictionary(grouping: document.rows.filter { $0.group != 0 }, by: \.group)
            .mapValues(\.count)
        controller.lineGroups = counts.keys.sorted().map { (group: $0, lineCount: counts[$0]!) }
    }

    @objc func collocationsTapped(_ sender: Any) {
        let sheet = CollocationSheetController()
        sheet.corpusName = document.corpusName
        sheet.onRun = { [weak self] spec in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let items = try await self.document.collocations(spec)
                    self.show(CollocationWindowController(spec: spec, items: items))
                } catch {
                    self.showErrorAlert(error)
                }
            }
        }
        presentAsSheet(sheet)
    }

    @objc func frequenciesTapped(_ sender: Any) {
        let sheet = FrequencySheetController()
        sheet.corpusName = document.corpusName
        sheet.onRun = { [weak self] criterion, minFrequency in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let items = try await self.document.frequencyDistribution([criterion], minFrequency: minFrequency)
                    self.show(FrequencyWindowController(criterion: criterion, items: items))
                } catch {
                    self.showErrorAlert(error)
                }
            }
        }
        presentAsSheet(sheet)
    }

    /// Shows a disposable auxiliary results window and keeps it alive (see
    /// `auxiliaryWindowControllers`) until it's closed.
    private func show(_ windowController: NSWindowController) {
        auxiliaryWindowControllers.append(windowController)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: windowController.window, queue: .main
        ) { [weak self, weak windowController] _ in
            guard let self, let windowController else { return }
            auxiliaryWindowControllers.removeAll { $0 === windowController }
        }
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t run the request"
        alert.informativeText = "\(error)"
        if let window = windowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Table view

    private func setUpTableView() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .plain
        tableView.headerView = NSTableHeaderView()
        // NSTableView.allowsMultipleSelection defaults to false - only
        // matters for a programmatically-created table like this one, since
        // Interface Builder's default checkbox state is checked.
        tableView.allowsMultipleSelection = true

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
        left.sortDescriptorPrototype = NSSortDescriptor(key: Column.left.rawValue, ascending: true)

        let kwic = NSTableColumn(identifier: .init(Column.kwic.rawValue))
        kwic.title = "Match"
        kwic.resizingMask = .userResizingMask
        kwic.width = 160
        kwic.sortDescriptorPrototype = NSSortDescriptor(key: Column.kwic.rawValue, ascending: true)

        let right = NSTableColumn(identifier: .init(Column.right.rawValue))
        right.title = "Right"
        right.resizingMask = .autoresizingMask
        right.width = 270
        right.sortDescriptorPrototype = NSSortDescriptor(key: Column.right.rawValue, ascending: true)

        tableView.addTableColumn(group)
        tableView.addTableColumn(left)
        tableView.addTableColumn(kwic)
        tableView.addTableColumn(right)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.onSortDescriptorsChange = { [weak self] in self?.headerSortChanged($0) }

        dataSource = NSTableViewDiffableDataSource<Section, Int>(tableView: tableView) { [weak self] _, column, _, id in
            self?.makeCell(for: column, rowID: id) ?? NSView()
        }
        tableView.dataSource = dataSource

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
    }

    /// Header click (or programmatic assignment from `syncSortIndicators`)
    /// changed `tableView.sortDescriptors`. AppKit already computed the
    /// correct ascending/descending toggle for a re-click on the same
    /// column before calling this - see `SortableTableView`.
    private func headerSortChanged(_ descriptors: [NSSortDescriptor]) {
        guard !isSyncingSortIndicators,
              let descriptor = descriptors.first,
              let key = descriptor.key,
              let column = Column(rawValue: key) else { return }
        let anchor: SortAnchor
        switch column {
        case .left: anchor = .left
        case .kwic: anchor = .kwic
        case .right: anchor = .right
        case .group: return
        }
        let level = SortLevel(attribute: "word", anchor: anchor, span: 1)
        document.performSort(SortCriteria(level), descending: !descriptor.ascending)
    }

    /// Mirrors the document's actual current sort (however it was set - a
    /// header click, the toolbar's Sort popover, or after undo/redo) onto
    /// the column headers' indicator triangles. A sort that isn't a
    /// single-level "word" sort on one of these columns clears every
    /// indicator, since it doesn't correspond to any header.
    private func syncSortIndicators() {
        isSyncingSortIndicators = true
        defer { isSyncingSortIndicators = false }

        var matchedColumn: Column?
        var matchedAscending = true
        if let (level, descending) = document.operations.last(where: { $0.singleLevelSort != nil })?.singleLevelSort,
           level.attribute == "word" {
            switch level.anchor {
            case .left: matchedColumn = .left
            case .kwic: matchedColumn = .kwic
            case .right: matchedColumn = .right
            }
            matchedAscending = !descending
        }

        for column in tableView.tableColumns {
            guard let identifier = Column(rawValue: column.identifier.rawValue), identifier != .group else { continue }
            if identifier == matchedColumn {
                tableView.setIndicatorImage(
                    NSImage(named: matchedAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"),
                    in: column)
            } else {
                tableView.setIndicatorImage(nil, in: column)
            }
        }
        tableView.sortDescriptors = matchedColumn.map {
            [NSSortDescriptor(key: $0.rawValue, ascending: matchedAscending)]
        } ?? []
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
        syncSortIndicators()
        // If the Operations popover is open, its line-group rows are sourced
        // from `document.rows` (see `updateOperationsPopover`), which only
        // becomes current once the async replay triggered by a remove/clear
        // actually finishes - i.e. right here, not at the moment the button
        // was clicked. Without this, the popover shows stale line-group
        // counts until some *later* action happens to refresh it.
        if let activeOperationsPopover {
            updateOperationsPopover(activeOperationsPopover)
        }
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
        // Each selected row still becomes its own `.setLineGroup` operation
        // in the persisted chain, but as one batched operations-chain update
        // (see `performSetLineGroups`) - appending them one at a time here
        // used to fire one overlapping `replay()` per row and crash the
        // engine on a multi-row selection.
        document.performSetLineGroups(Array(targetedRows()), group: sender.tag)
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
