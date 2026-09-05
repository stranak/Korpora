import Cocoa

/// One window per `ConcordanceDocument`. Relies on AppKit's automatic native
/// window tabbing (the default for document-based apps) so several
/// concordances can sit side by side as tabs - no custom tab UI needed.
final class ConcordanceWindowController: NSWindowController, NSToolbarDelegate {
    enum ItemID {
        static let sort = NSToolbarItem.Identifier("sort")
        static let filter = NSToolbarItem.Identifier("filter")
        static let shuffle = NSToolbarItem.Identifier("shuffle")
        static let sample = NSToolbarItem.Identifier("sample")
        static let clearGroups = NSToolbarItem.Identifier("clearGroups")
    }

    private var sortButton: NSButton?
    private var filterButton: NSButton?
    private var shuffleButton: NSButton?
    private var sampleButton: NSButton?
    private var clearGroupsButton: NSButton?

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
        [ItemID.sort, ItemID.filter, ItemID.shuffle, ItemID.sample, .flexibleSpace, ItemID.clearGroups]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let viewController = window?.contentViewController as? ConcordanceViewController else { return nil }
        switch identifier {
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
        case ItemID.clearGroups:
            let button = makeButton(symbol: "xmark.circle", label: "Clear Groups", target: viewController,
                                     action: #selector(ConcordanceViewController.clearGroupsTapped(_:)))
            clearGroupsButton = button
            return makeItem(identifier, label: "Clear Groups", view: button)
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
    func updateToolbarState(hasLineGroups: Bool) {
        sortButton?.isEnabled = !hasLineGroups
        filterButton?.isEnabled = !hasLineGroups
        shuffleButton?.isEnabled = !hasLineGroups
        sampleButton?.isEnabled = !hasLineGroups
        clearGroupsButton?.isEnabled = hasLineGroups
    }
}
