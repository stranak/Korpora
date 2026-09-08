import Cocoa

/// The classic macOS multi-pane Settings/Preferences window (`Cmd-,`): a
/// `.preference`-styled toolbar switching a single content view controller,
/// same pattern System Settings and most Mac apps have used for decades.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private enum Pane: String, CaseIterable {
        case general, appearance, concordance, corpora

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .concordance: return "Concordance"
            case .corpora: return "Corpora"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "textformat"
            case .concordance: return "text.alignleft"
            case .corpora: return "internaldrive"
            }
        }

        var identifier: NSToolbarItem.Identifier { .init(rawValue) }

        func makeViewController() -> NSViewController {
            switch self {
            case .general: return GeneralSettingsViewController()
            case .appearance: return AppearanceSettingsViewController()
            case .concordance: return ConcordanceSettingsViewController()
            case .corpora: return CorporaSettingsViewController()
            }
        }
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.center()
        self.init(window: window)

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        showPane(.general)
    }

    private func showPane(_ pane: Pane) {
        guard let window else { return }
        window.title = pane.title
        window.contentViewController = pane.makeViewController()
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
