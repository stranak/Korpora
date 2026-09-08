import Cocoa
import ManateeKit
import UniformTypeIdentifiers

final class ConcordanceViewController: NSViewController {
    private enum Section { case main }
    private enum Column: String { case disclosure, group, doc, left, kwic, right }

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

    // Inline "Extended Context" (`AppSettings.extendedContextDisplayMode
    // == .inline`) - transient UI state, not part of `ConcordanceDocument`,
    // since it's purely presentational and doesn't survive a real replay
    // (see `refresh(animated:)`).
    //
    // A set/dictionary rather than 6.6's single `expandedRowID: Int?`,
    // because `AppSettings.allowMultipleExtendedContexts` (6.6a) lets any
    // number of rows be expanded at once. With that setting off these still
    // never hold more than one entry - `collapseAllExpansions` runs first -
    // so the one-at-a-time default is preserved exactly.
    private var expandedRowIDs: Set<Int> = []
    private var expandedContexts: [Int: (before: String, match: String, after: String)] = [:]

    /// Governs both presentations - see `AppSettings
    /// .allowMultipleExtendedContexts`. Read fresh rather than cached, so
    /// flipping it in Settings takes effect on the next interaction
    /// without needing a `settingsDidChange` hook.
    private var allowsMultipleExtendedContexts: Bool {
        AppSettings.shared.allowMultipleExtendedContexts
    }

    weak var windowController: ConcordanceWindowController?

    /// `ConcordanceWindowController` needs this to set the "KWIC | Sentence"
    /// segmented control's initial selection and the Context button's
    /// initial enabled state, both at toolbar-item-creation time, before
    /// any `refresh()`/`updateToolbarState` call happens - `document`
    /// itself stays `private` since nothing else needs broader access.
    var viewMode: ConcordanceViewMode { document.viewMode }

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

        document.onResultsChanged = { [weak self] animated in self?.refresh(animated: animated) }
        refresh()

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange), name: AppSettings.didChangeNotification, object: nil)
    }

    /// A font/color-setting change doesn't touch `document.rows`, so the
    /// diffable data source (keyed on row `id`, not content) wouldn't
    /// otherwise know to redraw anything - force every visible cell to
    /// rebuild. Also re-applies `usesAlternatingRowBackground`, the one
    /// setting that lives on the table view itself rather than being read
    /// fresh per-cell.
    @objc private func settingsDidChange() {
        tableView.usesAlternatingRowBackgroundColors = AppSettings.shared.usesAlternatingRowBackground
        // `allowMultipleExtendedContexts` (6.6a) can be toggled while this
        // window is open: show/hide the triangle column to match, and if
        // it was just switched *off* while several rows were expanded,
        // collapse them rather than leaving a state the setting no longer
        // permits (and which nothing would then bring back into line).
        updateDisclosureColumn()
        if !allowsMultipleExtendedContexts, expandedRowIDs.count > 1 {
            collapseAllExpansions()
        }
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

    @objc func viewModeChanged(_ sender: NSSegmentedControl) {
        document.setViewMode(sender.selectedSegment == 1 ? .sentence : .kwic)
    }

    @objc func attributesTapped(_ sender: NSButton) {
        let popover = NSPopover()
        let controller = AttributeDisplayPopoverController()
        controller.corpusName = document.corpusName
        controller.primaryAttribute = document.kwicAttr
        controller.selectedInlineAttributes = document.inlineAttributes
        controller.selectedTooltipAttributes = document.tooltipAttributes
        controller.selectedStructuralAttribute = document.structuralAttributeToShow
        controller.onApply = { [weak self, weak popover] inlineAttributes, tooltipAttributes, structuralAttribute in
            guard let self else { return }
            document.setAttributeDisplay(inlineAttributes: inlineAttributes, tooltipAttributes: tooltipAttributes)
            document.setStructuralAttributeDisplay(structuralAttribute)
            updateStructuralColumn()
            popover?.close()
        }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    /// The structural-attribute column is hidden entirely (rather than
    /// always shown but empty) whenever no structural attribute is
    /// configured, and titled after whichever one is - e.g. "doc.title",
    /// not a fixed "Doc" - so multiple lines' worth of context isn't
    /// needed to tell what the column even shows. The initial state
    /// (including for a reopened saved document already carrying a
    /// non-nil `structuralAttributeToShow`) is set directly in
    /// `setUpTableView`; this is the update path for `attributesTapped`'s
    /// Apply changing it afterward.
    private func updateStructuralColumn() {
        guard let column = tableView.tableColumn(withIdentifier: .init(Column.doc.rawValue)) else { return }
        column.isHidden = document.structuralAttributeToShow == nil
        column.title = document.structuralAttributeToShow ?? "Doc"
    }

    @objc func historyTapped(_ sender: NSButton) {
        let popover = NSPopover()
        let controller = HistoryPopoverController()
        controller.entries = QueryHistoryStore.recentEntries()
        controller.onSelect = { [weak self, weak popover] entry in
            guard let self else { return }
            queryField.text = entry.query
            document.corpusName = entry.corpusName
            document.subcorpusPath = entry.subcorpusPath
            document.runQuery(entry.query)
            popover?.close()
        }
        controller.onClear = { [weak controller] in
            QueryHistoryStore.clear()
            controller?.entries = []
        }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc func contextTapped(_ sender: NSButton) {
        let popover = NSPopover()
        let currentLeft = Int(document.leftContext.replacingOccurrences(of: "-", with: "")) ?? 10
        let currentRight = Int(document.rightContext) ?? 10
        let controller = ContextPopoverController(left: currentLeft, right: currentRight)
        controller.onApply = { [weak self, weak popover] left, right in
            self?.document.setContext(left: left, right: right)
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

    /// File-menu action (see `AppDelegate.makeMainMenu`) - resolved via the
    /// responder chain rather than a direct target, so it's only enabled
    /// while a concordance window is key.
    @objc func exportConcordance(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.nameFieldStringValue = document.corpusName.isEmpty ? "Concordance.csv" : "\(document.corpusName).csv"
        let accessory = ExportAccessoryView()
        // Defaults to whatever's currently shown inline in the table, so
        // the export matches what the user is looking at unless they say
        // otherwise.
        accessory.includeInlineAttributes = !document.inlineAttributes.isEmpty
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let format: ConcordanceExportFormat = url.pathExtension.lowercased() == "csv" ? .commaSeparated : .tabSeparated
            let inlineAttributes = accessory.includeInlineAttributes ? self.document.inlineAttributes : []
            let text = ConcordanceExporter.export(rows: self.document.rows, format: format, inlineAttributes: inlineAttributes)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.showErrorAlert(error)
            }
        }
    }

    /// File-menu action (see `AppDelegate.makeMainMenu`) - hands the table
    /// straight to the standard macOS print panel rather than building a
    /// bespoke PDF export: the print panel already offers "Save as PDF",
    /// so this covers both without a second code path.
    @objc func printConcordance(_ sender: Any?) {
        guard let window = view.window else { return }
        tableView.printHeaderLines = [
            CQLQueryField.syntaxColoredAttributedString(
                for: document.initialQuery, font: .monospacedSystemFont(ofSize: 12, weight: .regular)),
            NSAttributedString(string: document.status, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ]),
        ]
        let operation = NSPrintOperation(view: tableView)
        // Room for `printHeaderLines`, drawn in `drawPageBorder` - without
        // widening this, the header text would overlap the table's own
        // first row rather than sitting above it.
        operation.printInfo.topMargin = 54
        operation.printInfo.horizontalPagination = .fit
        operation.printInfo.verticalPagination = .automatic
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
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
        tableView.usesAlternatingRowBackgroundColors = AppSettings.shared.usesAlternatingRowBackground
        tableView.style = .plain
        tableView.headerView = NSTableHeaderView()
        // NSTableView.allowsMultipleSelection defaults to false - only
        // matters for a programmatically-created table like this one, since
        // Interface Builder's default checkbox state is checked.
        tableView.allowsMultipleSelection = true

        // Per-row expand/collapse triangle for inline Extended Context
        // (6.6a). Only shown when several rows may be expanded at once -
        // see `updateDisclosureColumn` for why, and note the overlay's
        // leading inset deliberately clears this column so the triangle
        // stays clickable while its own row is expanded.
        let disclosure = NSTableColumn(identifier: .init(Column.disclosure.rawValue))
        disclosure.title = ""
        disclosure.width = 18
        disclosure.minWidth = 18
        disclosure.maxWidth = 18
        disclosure.resizingMask = []
        disclosure.isHidden = !allowsMultipleExtendedContexts

        let group = NSTableColumn(identifier: .init(Column.group.rawValue))
        group.title = ""
        group.width = 32
        group.minWidth = 32
        group.maxWidth = 32
        group.resizingMask = []

        // Fixed-width (manual drag only, no auto-grow) like `group` - a
        // structural attribute value (e.g. "doc.title") is constant for
        // the whole line, so it doesn't participate in the Left/Right
        // symmetric-growth centering below. Hidden (zero width) and
        // titled after the chosen attribute unless
        // `document.structuralAttributeToShow` is set - see
        // `updateStructuralColumn`.
        let doc = NSTableColumn(identifier: .init(Column.doc.rawValue))
        doc.title = document.structuralAttributeToShow ?? "Doc"
        doc.resizingMask = .userResizingMask
        doc.width = 120
        doc.minWidth = 0
        doc.isHidden = document.structuralAttributeToShow == nil

        // Left/Right both auto-resize (and start at equal widths) while
        // Match only resizes by manual drag - combined with
        // `.uniformColumnAutoresizingStyle` below, this keeps Left and
        // Right growing together as the window widens, so Match (the
        // actual keyword) stays visually centered instead of drifting
        // left the way `.lastColumnOnlyAutoresizingStyle` (widening only
        // the last column) used to make it.
        let left = NSTableColumn(identifier: .init(Column.left.rawValue))
        left.title = "Left"
        left.resizingMask = [.userResizingMask, .autoresizingMask]
        left.width = 270
        left.sortDescriptorPrototype = NSSortDescriptor(key: Column.left.rawValue, ascending: true)

        let kwic = NSTableColumn(identifier: .init(Column.kwic.rawValue))
        kwic.title = "Match"
        kwic.resizingMask = .userResizingMask
        kwic.width = 160
        kwic.sortDescriptorPrototype = NSSortDescriptor(key: Column.kwic.rawValue, ascending: true)

        let right = NSTableColumn(identifier: .init(Column.right.rawValue))
        right.title = "Right"
        right.resizingMask = [.userResizingMask, .autoresizingMask]
        right.width = 270
        right.sortDescriptorPrototype = NSSortDescriptor(key: Column.right.rawValue, ascending: true)

        tableView.addTableColumn(disclosure)
        tableView.addTableColumn(group)
        tableView.addTableColumn(doc)
        tableView.addTableColumn(left)
        tableView.addTableColumn(kwic)
        tableView.addTableColumn(right)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.onSortDescriptorsChange = { [weak self] in self?.headerSortChanged($0) }

        dataSource = NSTableViewDiffableDataSource<Section, Int>(tableView: tableView) { [weak self] _, column, _, id in
            self?.makeCell(for: column, rowID: id) ?? NSView()
        }
        tableView.dataSource = dataSource
        tableView.delegate = self
        // Double-click a line to show its Extended Context (6.6a) - the
        // same action the "Extended Context…" context-menu item runs, and
        // like it, keyed off `clickedRow`. AppKit reports `clickedRow ==
        // -1` for a double-click that didn't land on a row (the header,
        // or empty space below the last line), which `showExtendedContext`
        // already rejects via its `rows.indices.contains` guard - so a
        // double-click on a sort header can't be mistaken for a row.
        tableView.target = self
        tableView.doubleAction = #selector(showExtendedContext(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        // Left/Right auto-grow with the window (see the comment above on
        // `left`/`right`), so the currently-expanded row's word-wrapped
        // height (sized to those columns' widths - see
        // `tableView(_:heightOfRow:)`) needs recomputing after a resize,
        // not just after the row is first expanded.
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnDidResize), name: NSTableView.columnDidResizeNotification, object: tableView)
    }

    /// Left/Right auto-grow changes the table's width, so every expanded
    /// row's word-wrapped height needs recomputing - all of them now, not
    /// just one (6.6a). Dragging the structural-attribute column also
    /// moves the overlay's leading inset, so the on-screen overlays get
    /// re-laid-out here too.
    @objc private func columnDidResize(_ notification: Notification) {
        guard !expandedRowIDs.isEmpty else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(expandedRowIDs))
        for row in expandedRowIDs {
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { continue }
            applyOverlay(to: rowView, row: row)
        }
    }

    /// Shows/hides the 6.6a disclosure-triangle column to match
    /// `AppSettings.allowMultipleExtendedContexts`, which can be toggled
    /// while a concordance window is already open (see
    /// `settingsDidChange`).
    private func updateDisclosureColumn() {
        guard let column = tableView.tableColumns.first(
            where: { $0.identifier.rawValue == Column.disclosure.rawValue }) else { return }
        column.isHidden = !allowsMultipleExtendedContexts
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
        case .disclosure, .group, .doc: return
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
            guard let identifier = Column(rawValue: column.identifier.rawValue),
                  identifier != .group, identifier != .doc else { continue }
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
        let kind = column.flatMap { Column(rawValue: $0.identifier.rawValue) }
        // An expanded row's *text* is rendered entirely by the overlay
        // `applyOverlay` adds to its `NSTableRowView` (one continuous
        // paragraph, not chopped by column boundaries), so the Left/Match/
        // Right cells underneath go blank. The leading metadata columns
        // are the exception (6.6a item 2): the overlay now starts to their
        // right rather than covering them, so they keep their content -
        // that's the whole point, since a covered disclosure triangle
        // couldn't be clicked to collapse the row again.
        if expandedRowIDs.contains(rowID), let kind, !Self.leadingMetadataColumns.contains(kind) {
            return NSView()
        }
        let row = document.rows[rowID]
        if kind == .disclosure {
            return makeDisclosureCell(rowID: rowID)
        }
        let cell = KWICCellView()
        let inlineAttributes = document.inlineAttributes
        let tooltipAttributes = document.tooltipAttributes
        func configure(_ tokens: [KWICToken], alignment: NSTextAlignment, style: KWICCellView.Style) {
            let displayLine = KWICFormatter.displayLine(
                for: tokens, inlineAttributes: inlineAttributes, tooltipAttributes: tooltipAttributes)
            cell.configure(displayLine: displayLine, alignment: alignment, style: style)
        }
        switch kind {
        case .group:
            cell.configureGroup(row.group)
        case .doc:
            cell.configureStructuralInfo(row.structuralAttributeValue ?? "")
        case .left:
            configure(row.line.leftTokens, alignment: .right, style: .plain)
        case .kwic:
            configure(row.line.kwicTokens, alignment: .center, style: .highlighted)
        case .right:
            configure(row.line.rightTokens, alignment: .left, style: .plain)
        case .disclosure, nil:
            break
        }
        return cell
    }

    /// The columns that sit *left* of the KWIC text and hold per-line
    /// metadata rather than context - the inline Extended Context overlay
    /// starts to their right (see `overlayLeadingInset`) instead of
    /// spanning the literal full row width as it did in 6.6.
    ///
    /// All three, not just `doc`: the user's report named the structural
    /// attribute column, but a paragraph starting at x=0 runs over a
    /// visible line-group number just as badly, and over the disclosure
    /// triangle it would break collapsing outright.
    private static let leadingMetadataColumns: Set<Column> = [.disclosure, .group, .doc]

    /// A disclosure triangle whose state mirrors whether `rowID` is
    /// currently expanded. `tag` carries the row id through to
    /// `disclosureToggled` - the cheapest way to get it back, since a
    /// diffable data source hands cells out per row id anyway.
    private func makeDisclosureCell(rowID: Int) -> NSView {
        let button = NSButton()
        button.bezelStyle = .disclosure
        button.setButtonType(.onOff)
        button.title = ""
        button.tag = rowID
        button.state = expandedRowIDs.contains(rowID) ? .on : .off
        button.target = self
        button.action = #selector(disclosureToggled(_:))
        button.setAccessibilityLabel("Extended context")
        let container = NSView()
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        // Top-aligned on an expanded row, whose cell is as tall as the
        // whole wrapped paragraph - centering there would strand the
        // triangle halfway down a tall row, far from the line it belongs
        // to. A collapsed row is one line tall, so centering is right.
        let vertical = expandedRowIDs.contains(rowID)
            ? button.topAnchor.constraint(equalTo: container.topAnchor, constant: 2)
            : button.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            vertical,
        ])
        return container
    }

    @objc private func disclosureToggled(_ sender: NSButton) {
        toggleInlineExtendedContext(for: sender.tag)
    }

    /// Toggles the inline "Extended Context" expansion for `row` - see
    /// `AppSettings.extendedContextDisplayMode`. Re-triggering an
    /// already-expanded row always collapses it, whichever trigger was
    /// used (context menu, double-click, or the 6.6a disclosure triangle).
    ///
    /// Expanding a *different* row depends on
    /// `allowMultipleExtendedContexts`: with it on, the new row joins the
    /// existing expansions; with it off, they all collapse first, which is
    /// exactly 6.6's single-expansion behavior.
    private func toggleInlineExtendedContext(for row: Int) {
        guard document.rows.indices.contains(row) else { return }
        if expandedRowIDs.contains(row) {
            expandedRowIDs.remove(row)
            expandedContexts[row] = nil
            applyExpansionChange(affected: [row])
            return
        }
        Task { @MainActor in
            do {
                let context = try await document.extendedContext(at: row)
                // Re-checked after the await, not before: the row could
                // have been collapsed (or the whole table replayed) while
                // the fetch was in flight.
                guard document.rows.indices.contains(row) else { return }
                var changed = [row]
                if !allowsMultipleExtendedContexts {
                    changed.append(contentsOf: expandedRowIDs.filter { $0 != row })
                    expandedRowIDs.removeAll()
                    expandedContexts.removeAll()
                }
                expandedRowIDs.insert(row)
                expandedContexts[row] = context
                applyExpansionChange(affected: changed)
            } catch {
                self.showErrorAlert(error)
            }
        }
    }

    /// Collapses every inline expansion, refreshing whichever rows were
    /// affected. Used by `refresh(animated:)` (a replay renumbers row ids,
    /// so an expansion no longer refers to a meaningful line) and by
    /// `settingsDidChange` when multi-expansion is switched off while more
    /// than one row is open.
    private func collapseAllExpansions() {
        guard !expandedRowIDs.isEmpty else { return }
        let previously = Array(expandedRowIDs)
        expandedRowIDs.removeAll()
        expandedContexts.removeAll()
        for row in previously {
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { continue }
            applyOverlay(to: rowView, row: row)
        }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(previously))
    }

    /// Common tail of every expand/collapse transition: resize the
    /// affected row(s), swap their column cells between blank/normal
    /// content, and add/remove the overlay on whichever row view(s) are
    /// currently on-screen for them (a row that's scrolled out of view
    /// has no row view yet - `tableView(_:didAdd:forRow:)` covers that
    /// case once it scrolls back in, reading the by-then-current
    /// `expandedRowID`/`expandedContext`).
    private func applyExpansionChange(affected rows: [Int]) {
        guard !rows.isEmpty else { return }
        let indexes = IndexSet(rows)
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        for row in rows {
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { continue }
            applyOverlay(to: rowView, row: row)
        }
    }

    /// Adds, updates, or removes the inline Extended Context overlay on
    /// `rowView` depending on whether `row` is currently expanded -
    /// idempotent, since it's called both eagerly (see
    /// `applyExpansionChange`) and passively whenever AppKit hands back
    /// a row view (`tableView(_:didAdd:forRow:)`), including a recycled
    /// one that may already carry a stale overlay from a different row.
    ///
    /// That recycling case matters more now than it did in 6.6: with
    /// several rows expandable at once, a recycled row view is more likely
    /// to arrive carrying an overlay, and both "was expanded, now isn't"
    /// and "was expanded, still is but for a *different* row's text" have
    /// to resolve correctly. Keying every branch off `expandedContexts[row]`
    /// (never off remembered per-view state) is what makes that safe.
    private func applyOverlay(to rowView: NSTableRowView, row: Int) {
        let existing = rowView.subviews.compactMap { $0 as? ExtendedContextOverlayField }.first
        guard expandedRowIDs.contains(row), let context = expandedContexts[row] else {
            existing?.removeFromSuperview()
            return
        }
        let overlay = existing ?? makeOverlayField(in: rowView)
        overlay.attributedStringValue = KWICCellView.extendedContextParagraph(
            before: context.before, match: context.match, after: context.after)
        // Re-applied on every call, not just at creation: the structural
        // attribute column can be shown/hidden or dragged wider at any
        // time, and a recycled overlay carries the previous row's inset.
        overlay.leadingInset?.constant = overlayLeadingInset()
    }

    /// Where the inline paragraph starts, measured from the row view's
    /// leading edge - far enough right to clear the metadata columns (see
    /// `leadingMetadataColumns`) so it doesn't render over the structural
    /// attribute value, the line-group number, or the disclosure triangle.
    private func overlayLeadingInset() -> CGFloat {
        let widths = tableView.tableColumns
            .filter { column in
                guard let kind = Column(rawValue: column.identifier.rawValue) else { return false }
                return Self.leadingMetadataColumns.contains(kind) && !column.isHidden
            }
            .map(\.width)
        return Self.overlayLeadingInset(visibleMetadataColumnWidths: widths)
    }

    /// The arithmetic behind `overlayLeadingInset()`, split out as a pure
    /// function so it can be unit-tested without an `NSTableView` (see
    /// `ExtendedContextOverlayInsetTests`) - AppKit column geometry is
    /// otherwise only reachable from a live, laid-out window.
    ///
    /// `NSTableView` puts `intercellSpacing.width` between columns, so a
    /// visible metadata column occupies its own width plus that gap; the
    /// trailing `textPadding` then matches the 8pt the overlay has always
    /// used against the row's leading edge, keeping the paragraph from
    /// butting up against the column to its left.
    static func overlayLeadingInset(
        visibleMetadataColumnWidths widths: [CGFloat],
        intercellSpacing: CGFloat = 3,
        textPadding: CGFloat = 8
    ) -> CGFloat {
        guard !widths.isEmpty else { return textPadding }
        return widths.reduce(0) { $0 + $1 + intercellSpacing } + textPadding
    }

    private func makeOverlayField(in rowView: NSTableRowView) -> ExtendedContextOverlayField {
        let field = ExtendedContextOverlayField(wrappingLabelWithString: "")
        field.isSelectable = false
        field.isEditable = false
        field.drawsBackground = false
        field.maximumNumberOfLines = 0
        field.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(field)
        let leading = field.leadingAnchor.constraint(
            equalTo: rowView.leadingAnchor, constant: overlayLeadingInset())
        field.leadingInset = leading
        NSLayoutConstraint.activate([
            leading,
            field.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: rowView.topAnchor, constant: 4),
            field.bottomAnchor.constraint(equalTo: rowView.bottomAnchor, constant: -4),
        ])
        return field
    }

    private func refresh(animated: Bool = true) {
        if queryField.text != document.initialQuery {
            queryField.text = document.initialQuery
        }
        // A real replay (as opposed to a display-only refetch, e.g. after
        // a settings change - see `settingsDidChange`, which calls
        // `tableView.reloadData()` directly rather than through here) can
        // renumber/reorder row ids, so any inline Extended Context
        // expansion no longer refers to a meaningful row.
        if animated {
            collapseAllExpansions()
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
        dataSource.apply(snapshot, animatingDifferences: animated)
        windowController?.updateToolbarState(hasLineGroups: document.hasLineGroups, viewMode: document.viewMode)
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

    @objc private func showDocumentInfo(_ sender: Any) {
        let row = tableView.clickedRow
        guard document.rows.indices.contains(row) else { return }
        Task { @MainActor in
            do {
                let info = try await document.structuralInfo(at: row)
                let alert = NSAlert()
                alert.messageText = "Document Info"
                alert.informativeText = info.isEmpty
                    ? "No structural attribute values for this line."
                    : info.map { "\($0.structure).\($0.attribute): \($0.value)" }.joined(separator: "\n")
                alert.runModal()
            } catch {
                self.showErrorAlert(error)
            }
        }
    }

    /// Row context-menu action, same single-clicked-row precedent as
    /// `showDocumentInfo` right above - matches the user's "if only one
    /// selected" framing for Extended Context, since a right-click
    /// context menu already only ever targets one row. Branches on
    /// `AppSettings.extendedContextDisplayMode`: `.sheet` is the original
    /// popup; `.inline` expands the row itself in place instead.
    @objc private func showExtendedContext(_ sender: Any) {
        let row = tableView.clickedRow
        guard document.rows.indices.contains(row) else { return }
        guard AppSettings.shared.extendedContextDisplayMode == .inline else {
            Task { @MainActor in
                do {
                    let (before, match, after) = try await document.extendedContext(at: row)
                    let info = try await document.extendedContextInfo(at: row)
                    // Unless several are allowed (6.6a), a new Extended
                    // Context replaces the open one instead of stacking -
                    // matching what the sheet it replaced could do, and
                    // what inline mode does in the same setting. Only
                    // Extended Context windows are closed: Collocations/
                    // Frequency share `auxiliaryWindowControllers` but
                    // aren't governed by this setting.
                    if !allowsMultipleExtendedContexts {
                        closeExtendedContextWindows()
                    }
                    show(ExtendedContextWindowController(info: info, before: before, match: match, after: after))
                } catch {
                    self.showErrorAlert(error)
                }
            }
            return
        }
        toggleInlineExtendedContext(for: row)
    }

    /// Closes any open Extended Context windows. `show(_:)`'s
    /// `willCloseNotification` observer is what actually drops them from
    /// `auxiliaryWindowControllers`, so this doesn't prune the array
    /// itself. `close()` posts that notification *synchronously*, so the
    /// observer mutates `auxiliaryWindowControllers` mid-loop - safe only
    /// because Swift's array value semantics mean `for ... in` walks the
    /// value captured when the loop began, not the live property.
    private func closeExtendedContextWindows() {
        for controller in auxiliaryWindowControllers where controller is ExtendedContextWindowController {
            controller.close()
        }
    }
}

extension ConcordanceViewController: NSTableViewDelegate {
    /// Only an expanded row (inline Extended Context - see
    /// `expandedRowIDs`) ever differs from `tableView.rowHeight`; sized to
    /// how tall its paragraph needs to be at the row's *current* width
    /// (kept correct across window resizes by `columnDidResize`, since
    /// Left/Right auto-growing changes the table's own width too).
    ///
    /// The available width now subtracts the metadata columns the overlay
    /// no longer covers (6.6a item 2) - otherwise a row with the
    /// structural attribute column showing would be measured wider than
    /// the paragraph actually gets to be, and come out too short.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard expandedRowIDs.contains(row), let context = expandedContexts[row] else {
            return tableView.rowHeight
        }
        let paragraph = KWICCellView.extendedContextParagraph(
            before: context.before, match: context.match, after: context.after)
        let available = tableView.bounds.width - overlayLeadingInset() - 8
        let height = KWICCellView.extendedContextHeight(for: paragraph, width: max(available, 100))
        return max(tableView.rowHeight, height + 8)
    }

    /// The passive counterpart to `applyExpansionChange`'s eager overlay
    /// management - fires whenever AppKit hands back a row view,
    /// including one newly scrolled into view (never touched by
    /// `applyExpansionChange`, since it wasn't on-screen yet) or a
    /// recycled one that used to represent a different, possibly
    /// still-expanded row.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        applyOverlay(to: rowView, row: row)
    }
}

/// Marker subclass so the inline Extended Context overlay (one
/// continuous paragraph spanning everything right of the metadata columns
/// - see `applyOverlay`) can be found among a recycled `NSTableRowView`'s
/// subviews and removed/reused, without separate tagging or
/// associated-object bookkeeping. It also carries its own leading
/// constraint, since that inset is recomputed whenever the structural
/// attribute column appears, disappears, or is resized.
private final class ExtendedContextOverlayField: NSTextField {
    var leadingInset: NSLayoutConstraint?
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

        menu.addItem(.separator())
        let infoItem = NSMenuItem(title: "Document Info…", action: #selector(showDocumentInfo(_:)), keyEquivalent: "")
        infoItem.target = self
        menu.addItem(infoItem)
        let extendedContextItem = NSMenuItem(
            title: "Extended Context…", action: #selector(showExtendedContext(_:)), keyEquivalent: "")
        extendedContextItem.target = self
        menu.addItem(extendedContextItem)
    }
}

/// The Export Concordance save panel's accessory view - one checkbox,
/// self-contained rather than a separate file since it has no purpose
/// outside `exportConcordance(_:)`.
private final class ExportAccessoryView: NSView {
    private let checkbox = NSButton(checkboxWithTitle: "Include Inline Attributes", target: nil, action: nil)

    var includeInlineAttributes: Bool {
        get { checkbox.state == .on }
        set { checkbox.state = newValue ? .on : .off }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 36))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            checkbox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
