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
        static let context = NSToolbarItem.Identifier("context")
        static let collocations = NSToolbarItem.Identifier("collocations")
        static let frequencies = NSToolbarItem.Identifier("frequencies")
        static let operations = NSToolbarItem.Identifier("operations")
    }

    private var sortButton: NSButton?
    private var filterButton: NSButton?
    private var shuffleButton: NSButton?
    private var sampleButton: NSButton?

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
        [ItemID.history, ItemID.sort, ItemID.filter, ItemID.shuffle, ItemID.sample, ItemID.context,
         ItemID.collocations, ItemID.frequencies, .flexibleSpace, ItemID.operations]
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
            let button = makeButton(symbol: "clock.arrow.circlepath", label: "History", target: viewController,
                                     action: #selector(ConcordanceViewController.historyTapped(_:)))
            return makeItem(identifier, label: "History", view: button)
        case ItemID.sort:
            let button = makeButton(symbol: "arrow.up.arrow.down", label: "Sort", target: viewController,
                                     action: #selector(ConcordanceViewController.sortTapped(_:)))
            sortButton = button
            return makeItem(identifier, label: "Sort", view: button)
        case ItemID.filter:
            let button = makeButton(symbol: "line.3.horizontal.decrease.circle", label: "Filter", target: viewController,
                                     action: #selector(ConcordanceViewController.filterTapped(_:)))
            filterButton = button
            return makeItem(identifier, label: "Filter", view: button)
        case ItemID.shuffle:
            let button = makeButton(symbol: "shuffle", label: "Shuffle", target: viewController,
                                     action: #selector(ConcordanceViewController.shuffleTapped(_:)))
            shuffleButton = button
            return makeItem(identifier, label: "Shuffle", view: button)
        case ItemID.sample:
            let button = makeButton(symbol: "number", label: "Sample", target: viewController,
                                     action: #selector(ConcordanceViewController.sampleTapped(_:)))
            sampleButton = button
            return makeItem(identifier, label: "Sample", view: button)
        case ItemID.context:
            // Not tracked in a stored property/`updateToolbarState` - unlike
            // sort/filter/shuffle/sample, widening context is a display
            // setting (see `ConcordanceDocument.setContext`), not a corpus
            // operation, so it never needs to disable when line groups exist.
            let button = makeButton(symbol: "arrow.left.and.right", label: "Context", target: viewController,
                                     action: #selector(ConcordanceViewController.contextTapped(_:)))
            return makeItem(identifier, label: "Context", view: button)
        case ItemID.collocations:
            let button = makeButton(symbol: "arrow.left.arrow.right", label: "Collocations", target: viewController,
                                     action: #selector(ConcordanceViewController.collocationsTapped(_:)))
            return makeItem(identifier, label: "Collocations", view: button)
        case ItemID.frequencies:
            let button = makeButton(symbol: "chart.bar", label: "Frequencies", target: viewController,
                                     action: #selector(ConcordanceViewController.frequenciesTapped(_:)))
            return makeItem(identifier, label: "Frequencies", view: button)
        case ItemID.operations:
            // Icon carried over from the old standalone "Clear Groups"
            // button - merged into this one, since both are fundamentally
            // "review and cancel active operations" (see
            // OperationsPopoverController).
            let button = makeButton(symbol: "xmark.circle", label: "Operations", target: viewController,
                                     action: #selector(ConcordanceViewController.operationsTapped(_:)))
            return makeItem(identifier, label: "Operations", view: button)
        default:
            return nil
        }
    }

    private func makeButton(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
            target: target, action: action)
        button.bezelStyle = .texturedRounded
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
    func updateToolbarState(hasLineGroups: Bool) {
        sortButton?.isEnabled = !hasLineGroups
        filterButton?.isEnabled = !hasLineGroups
        shuffleButton?.isEnabled = !hasLineGroups
        sampleButton?.isEnabled = !hasLineGroups
    }
}
