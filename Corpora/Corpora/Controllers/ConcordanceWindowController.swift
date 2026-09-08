import Cocoa

/// One window per `ConcordanceDocument`. Relies on AppKit's automatic native
/// window tabbing (the default for document-based apps) so several
/// concordances can sit side by side as tabs - no custom tab UI needed.
final class ConcordanceWindowController: NSWindowController, NSToolbarDelegate {
    enum ItemID {
        static let history = NSToolbarItem.Identifier("history")
        static let sort = NSToolbarItem.Identifier("sort")
        static let filter = NSToolbarItem.Identifier("filter")
        static let shuffle = NSToolbarItem.Identifier("shuffle")
        static let sample = NSToolbarItem.Identifier("sample")
        static let viewMode = NSToolbarItem.Identifier("viewMode")
        static let context = NSToolbarItem.Identifier("context")
        static let attributes = NSToolbarItem.Identifier("attributes")
        static let collocations = NSToolbarItem.Identifier("collocations")
        static let frequencies = NSToolbarItem.Identifier("frequencies")
        static let operations = NSToolbarItem.Identifier("operations")
    }

    private var sortButton: NSButton?
    private var filterButton: NSButton?
    private var shuffleButton: NSButton?
    private var sampleButton: NSButton?
    private var contextButton: NSButton?

    convenience init(document: ConcordanceDocument) {
        let viewController = ConcordanceViewController(document: document)
        let window = NSWindow(contentViewController: viewController)
        window.setContentSize(NSSize(width: 820, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .preferred
        // ConcordanceDocument's own data(ofType:)/read(from:ofType:) is the
        // real reopen-a-concordance mechanism (see docs/project-plan.md's
        // NSDocument model) - the system's separate crash/relaunch window-restoration
        // path is redundant here and, if it ever finds stale state, can
        // silently swallow a launch (no window, no error).
        window.isRestorable = false
        self.init(window: window)
        viewController.windowController = self

        let toolbar = NSToolbar(identifier: "ConcordanceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.history, ItemID.sort, ItemID.filter, ItemID.shuffle, ItemID.sample, ItemID.viewMode, ItemID.context,
         ItemID.attributes, ItemID.collocations, ItemID.frequencies, .flexibleSpace, ItemID.operations]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let viewController = window?.contentViewController as? ConcordanceViewController else { return nil }
        switch identifier {
        case ItemID.history:
            // Not tracked in a stored property/`updateToolbarState` -
            // running a different query is always allowed regardless of
            // line groups (`ConcordanceDocument.runQuery` resets the whole
            // operation chain itself, same as typing into the query bar).
            let button = makeButton(
                symbol: "clock.arrow.circlepath", label: "History",
                tooltip: "Recall a recently run query", target: viewController,
                action: #selector(ConcordanceViewController.historyTapped(_:)))
            return makeItem(identifier, label: "History", view: button)
        case ItemID.sort:
            let button = makeButton(
                symbol: "arrow.up.arrow.down", label: "Sort",
                tooltip: "Sort concordance lines", target: viewController,
                action: #selector(ConcordanceViewController.sortTapped(_:)))
            sortButton = button
            return makeItem(identifier, label: "Sort", view: button)
        case ItemID.filter:
            let button = makeButton(
                symbol: "line.3.horizontal.decrease.circle", label: "Filter",
                tooltip: "Keep or remove lines matching a sub-query", target: viewController,
                action: #selector(ConcordanceViewController.filterTapped(_:)))
            filterButton = button
            return makeItem(identifier, label: "Filter", view: button)
        case ItemID.shuffle:
            let button = makeButton(
                symbol: "shuffle", label: "Shuffle",
                tooltip: "Randomize line order", target: viewController,
                action: #selector(ConcordanceViewController.shuffleTapped(_:)))
            shuffleButton = button
            return makeItem(identifier, label: "Shuffle", view: button)
        case ItemID.sample:
            let button = makeButton(
                symbol: "number", label: "Sample",
                tooltip: "Reduce to a random sample of lines", target: viewController,
                action: #selector(ConcordanceViewController.sampleTapped(_:)))
            sampleButton = button
            return makeItem(identifier, label: "Sample", view: button)
        case ItemID.viewMode:
            let segmented = NSSegmentedControl(
                labels: ["KWIC", "Sentence"], trackingMode: .selectOne,
                target: viewController, action: #selector(ConcordanceViewController.viewModeChanged(_:)))
            segmented.segmentStyle = .texturedRounded
            segmented.selectedSegment = viewController.viewMode == .sentence ? 1 : 0
            segmented.toolTip = "KWIC: fixed-width context. Sentence: expand to the enclosing sentence."
            return makeItem(identifier, label: "View", view: segmented)
        case ItemID.context:
            // Disabled in Sentence view - see `updateToolbarState` - since
            // a fixed-width context doesn't apply while context instead
            // expands to the enclosing sentence
            // (`ConcordanceDocument.effectiveLeftContext`/`.effectiveRightContext`).
            // Otherwise not tracked in a stored property/`updateToolbarState`
            // itself - unlike sort/filter/shuffle/sample, widening context is
            // a display setting (see `ConcordanceDocument.setContext`), not a
            // corpus operation, so it never needs to disable when line
            // groups exist.
            let button = makeButton(
                symbol: "arrow.left.and.right", label: "Context",
                tooltip: "Adjust how much left/right context is shown", target: viewController,
                action: #selector(ConcordanceViewController.contextTapped(_:)))
            button.isEnabled = viewController.viewMode != .sentence
            contextButton = button
            return makeItem(identifier, label: "Context", view: button)
        case ItemID.attributes:
            // Not tracked in a stored property/`updateToolbarState` - same
            // "pure display setting" reasoning as Context above.
            let button = makeButton(
                symbol: "textformat", label: "Attributes",
                tooltip: "Show additional attributes (e.g. lemma, tag) inline or on hover", target: viewController,
                action: #selector(ConcordanceViewController.attributesTapped(_:)))
            return makeItem(identifier, label: "Attributes", view: button)
        case ItemID.collocations:
            let button = makeButton(
                symbol: "arrow.left.arrow.right", label: "Collocations",
                tooltip: "Find words that co-occur with the search term", target: viewController,
                action: #selector(ConcordanceViewController.collocationsTapped(_:)))
            return makeItem(identifier, label: "Collocations", view: button)
        case ItemID.frequencies:
            let button = makeButton(
                symbol: "chart.bar", label: "Frequencies",
                tooltip: "Show a frequency distribution for an attribute", target: viewController,
                action: #selector(ConcordanceViewController.frequenciesTapped(_:)))
            return makeItem(identifier, label: "Frequencies", view: button)
        case ItemID.operations:
            // Icon carried over from the old standalone "Clear Groups"
            // button - merged into this one, since both are fundamentally
            // "review and cancel active operations" (see
            // OperationsPopoverController).
            let button = makeButton(
                symbol: "xmark.circle", label: "Operations",
                tooltip: "Review and remove active sort/filter/line-group operations", target: viewController,
                action: #selector(ConcordanceViewController.operationsTapped(_:)))
            return makeItem(identifier, label: "Operations", view: button)
        default:
            return nil
        }
    }

    private func makeButton(symbol: String, label: String, tooltip: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
            target: target, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        return button
    }

    private func makeItem(_ identifier: NSToolbarItem.Identifier, label: String, view: NSView) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.view = view
        return item
    }

    /// Custom-view toolbar items don't auto-validate - called from
    /// `ConcordanceViewController.refresh()` instead, mirroring KonText's own
    /// mutual-exclusion rule (line groups vs. sort/filter/shuffle/sample).
    /// The Operations button stays enabled regardless - reviewing/removing
    /// *existing* operations (including bulk-clearing line groups) doesn't
    /// conflict with an active line-group view the way starting a *new*
    /// sort/filter/shuffle/sample would.
    func updateToolbarState(hasLineGroups: Bool, viewMode: ConcordanceViewMode) {
        sortButton?.isEnabled = !hasLineGroups
        filterButton?.isEnabled = !hasLineGroups
        shuffleButton?.isEnabled = !hasLineGroups
        sampleButton?.isEnabled = !hasLineGroups
        contextButton?.isEnabled = viewMode != .sentence
    }
}
