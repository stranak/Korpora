import Cocoa

/// The classic macOS multi-pane Settings/Preferences window (`Cmd-,`): a
/// `.preference`-styled toolbar switching a single content view controller,
/// same pattern System Settings and most Mac apps have used for decades.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    enum Pane: String, CaseIterable {
        case corpora, appearance, concordance

        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .concordance: return "Concordance"
            case .corpora: return "Corpora"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "textformat"
            case .concordance: return "text.alignleft"
            case .corpora: return "internaldrive"
            }
        }

        var identifier: NSToolbarItem.Identifier { .init(rawValue) }

        func makeViewController() -> NSViewController {
            switch self {
            case .appearance: return AppearanceSettingsViewController()
            case .concordance: return ConcordanceSettingsViewController()
            case .corpora: return CorporaSettingsViewController()
            }
        }
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.center()
        self.init(window: window)

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        showPane(.corpora)
    }

    /// Each pane is laid out for a minimum size (its `preferredContentSize`)
    /// and is free to grow from there: the Corpora and Appearance lists take
    /// the extra height, the forms just get more room. Switching panes
    /// resizes the window to the new pane's own size, as preference windows
    /// do.
    func showPane(_ pane: Pane) {
        guard let window else { return }
        window.title = pane.title
        let controller = pane.makeViewController()
        // The size the pane was laid out for is its minimum and the size to
        // start at; it's taken from `preferredContentSize` and then cleared
        // *before* the pane is installed. AppKit turns a non-zero
        // `preferredContentSize` into constraints on the pane's view at
        // priority 501, one above the window's own size constraint, so the
        // window would snap back to that size after every resize.
        _ = controller.view  // loads it; the panes set their size in `loadView`
        let designedSize = controller.preferredContentSize
        controller.preferredContentSize = .zero
        window.contentViewController = controller
        window.contentMinSize = designedSize
        window.setContentSize(designedSize)
        window.toolbar?.selectedItemIdentifier = pane.identifier
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue) else { return }
        showPane(pane)
    }
}
