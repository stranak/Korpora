import Cocoa

/// Lets the user pick the font the concordance table renders results in,
/// via the standard Font Panel (`Cmd-T`) - the classic Mac way to pick a
/// font, rather than a bespoke family/size UI.
final class AppearanceSettingsViewController: NSViewController {
    private let fontLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))

        let label = NSTextField(labelWithString: "Results font:")
        let selectButton = NSButton(title: "Select…", target: self, action: #selector(selectFont))
        updateFontLabel()

        for view in [label, fontLabel, selectButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            fontLabel.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            fontLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),

            selectButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            selectButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
        ])

        view = root
        preferredContentSize = NSSize(width: 420, height: 140)
    }

    private func updateFontLabel() {
        let settings = AppSettings.shared
        fontLabel.stringValue = "\(settings.resultsFontName) \(Int(settings.resultsFontSize))pt"
    }

    @objc private func selectFont() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(AppSettings.shared.resultsFont, isMultiple: false)
        NSFontPanel.shared.orderFront(self)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let newFont = sender.convert(AppSettings.shared.resultsFont)
        AppSettings.shared.resultsFontName = newFont.fontName
        AppSettings.shared.resultsFontSize = Double(newFont.pointSize)
        updateFontLabel()
    }
}
