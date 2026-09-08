import Cocoa

/// Concordance-table styling: the results font (via the standard Font
/// Panel, `Cmd-T`), per-script font overrides, and the colors used for
/// positional/structural attributes and row striping. General app chrome
/// (menus/buttons/labels) deliberately has no override here - it stays on
/// the system font/colors throughout, matching this project's "stick to
/// the Macintosh HIG" preference; only *content* fonts/colors are
/// user-customizable, the same way e.g. Mail lets you pick a message-list
/// font without touching its own chrome.
final class AppearanceSettingsViewController: NSViewController {
    private let fontLabel = NSTextField(labelWithString: "")
    private let positionalColorWell = NSColorWell()
    private let structuralColorWell = NSColorWell()
    private let alternatingRowCheckbox = NSButton(
        checkboxWithTitle: "Alternate row background", target: nil, action: nil)
    private let scriptTableView = NSTableView()
    private let scriptScrollView = NSScrollView()

    /// Sorted for stable display - `AppSettings.scriptFontOverrides` is a
    /// plain `[String: String]` with no inherent order.
    private var scriptOverrideRows: [(script: UnicodeScript, fontName: String)] = []
    /// The script a "Select Font…" menu pick is for, until the Font Panel
    /// reports back a chosen font - see `pickScriptFont`/`scriptFontChanged`.
    private var pendingScript: UnicodeScript?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))

        let fontTitle = NSTextField(labelWithString: "Results font:")
        let selectFontButton = NSButton(title: "Select…", target: self, action: #selector(selectFont))
        updateFontLabel()

        let colorsTitle = NSTextField(labelWithString: "Colors:")
        colorsTitle.font = .boldSystemFont(ofSize: 12)
        let positionalLabel = NSTextField(labelWithString: "Positional attributes:")
        let structuralLabel = NSTextField(labelWithString: "Structural attribute:")
        positionalColorWell.color = AppSettings.shared.positionalAttributeColor
        positionalColorWell.target = self
        positionalColorWell.action = #selector(positionalColorChanged)
        structuralColorWell.color = AppSettings.shared.structuralAttributeColor
        structuralColorWell.target = self
        structuralColorWell.action = #selector(structuralColorChanged)

        alternatingRowCheckbox.state = AppSettings.shared.usesAlternatingRowBackground ? .on : .off
        alternatingRowCheckbox.target = self
        alternatingRowCheckbox.action = #selector(alternatingRowChanged)

        let scriptTitle = NSTextField(labelWithString: "Per-script fonts:")
        scriptTitle.font = .boldSystemFont(ofSize: 12)
        let scriptHint = NSTextField(wrappingLabelWithString:
            "Overrides the results font above for text in a specific script - useful when one font's "
                + "glyph coverage isn't ideal for every script a corpus's text contains.")
        scriptHint.font = .systemFont(ofSize: 11)
        scriptHint.textColor = .secondaryLabelColor

        scriptTableView.headerView = nil
        scriptTableView.addTableColumn(NSTableColumn(identifier: .init("override")))
        scriptTableView.dataSource = self
        scriptTableView.delegate = self
        scriptTableView.style = .plain
        scriptTableView.usesAlternatingRowBackgroundColors = true
        scriptScrollView.documentView = scriptTableView
        scriptScrollView.hasVerticalScroller = true
        scriptScrollView.borderType = .bezelBorder

        let addButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
            target: self, action: #selector(addOverrideTapped))
        let removeButton = NSButton(
            image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
            target: self, action: #selector(removeSelectedOverride))

        let views: [NSView] = [
            fontTitle, fontLabel, selectFontButton,
            colorsTitle, positionalLabel, positionalColorWell, structuralLabel, structuralColorWell,
            alternatingRowCheckbox,
            scriptTitle, scriptHint, scriptScrollView, addButton, removeButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        addButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        NSLayoutConstraint.activate([
            fontTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            fontTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            fontLabel.centerYAnchor.constraint(equalTo: fontTitle.centerYAnchor),
            fontLabel.leadingAnchor.constraint(equalTo: fontTitle.trailingAnchor, constant: 8),
            selectFontButton.topAnchor.constraint(equalTo: fontTitle.bottomAnchor, constant: 8),
            selectFontButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            colorsTitle.topAnchor.constraint(equalTo: selectFontButton.bottomAnchor, constant: 20),
            colorsTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            positionalLabel.topAnchor.constraint(equalTo: colorsTitle.bottomAnchor, constant: 10),
            positionalLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            positionalColorWell.centerYAnchor.constraint(equalTo: positionalLabel.centerYAnchor),
            positionalColorWell.leadingAnchor.constraint(equalTo: positionalLabel.trailingAnchor, constant: 8),
            positionalColorWell.widthAnchor.constraint(equalToConstant: 44),

            structuralLabel.topAnchor.constraint(equalTo: positionalLabel.bottomAnchor, constant: 8),
            structuralLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            structuralColorWell.centerYAnchor.constraint(equalTo: structuralLabel.centerYAnchor),
            structuralColorWell.leadingAnchor.constraint(equalTo: structuralLabel.trailingAnchor, constant: 8),
            structuralColorWell.widthAnchor.constraint(equalToConstant: 44),

            alternatingRowCheckbox.topAnchor.constraint(equalTo: structuralLabel.bottomAnchor, constant: 12),
            alternatingRowCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            scriptTitle.topAnchor.constraint(equalTo: alternatingRowCheckbox.bottomAnchor, constant: 20),
            scriptTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            scriptHint.topAnchor.constraint(equalTo: scriptTitle.bottomAnchor, constant: 4),
            scriptHint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scriptHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scriptScrollView.topAnchor.constraint(equalTo: scriptHint.bottomAnchor, constant: 8),
            scriptScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scriptScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scriptScrollView.heightAnchor.constraint(equalToConstant: 80),

            addButton.topAnchor.constraint(equalTo: scriptScrollView.bottomAnchor, constant: 6),
            addButton.leadingAnchor.constraint(equalTo: scriptScrollView.leadingAnchor),
            removeButton.topAnchor.constraint(equalTo: scriptScrollView.bottomAnchor, constant: 6),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 2),
            removeButton.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])

        view = root
        preferredContentSize = NSSize(width: 420, height: 400)
        reloadScriptOverrides()
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

    @objc private func positionalColorChanged() {
        AppSettings.shared.positionalAttributeColor = positionalColorWell.color
    }

    @objc private func structuralColorChanged() {
        AppSettings.shared.structuralAttributeColor = structuralColorWell.color
    }

    @objc private func alternatingRowChanged() {
        AppSettings.shared.usesAlternatingRowBackground = alternatingRowCheckbox.state == .on
    }

    private func reloadScriptOverrides() {
        let overrides = AppSettings.shared.scriptFontOverrides
        scriptOverrideRows = overrides.compactMap { key, fontName in
            UnicodeScript(rawValue: key).map { (script: $0, fontName: fontName) }
        }.sorted { $0.script.displayName < $1.script.displayName }
        scriptTableView.reloadData()
    }

    /// A pull-down of scripts not yet overridden (picking an already-
    /// overridden one would need a separate "change" affordance the
    /// remove-then-re-add flow already covers) - choosing one immediately
    /// opens the Font Panel for it, same "Select…" pattern as the base
    /// results font above.
    @objc private func addOverrideTapped(_ sender: NSButton) {
        let existing = Set(AppSettings.shared.scriptFontOverrides.keys)
        let menu = NSMenu()
        for script in UnicodeScript.allCases where script != .other && !existing.contains(script.rawValue) {
            let item = NSMenuItem(title: script.displayName, action: #selector(scriptPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = script
            menu.addItem(item)
        }
        guard !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func scriptPicked(_ sender: NSMenuItem) {
        guard let script = sender.representedObject as? UnicodeScript else { return }
        pendingScript = script
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(scriptFontChanged(_:))
        manager.setSelectedFont(AppSettings.shared.resultsFont, isMultiple: false)
        NSFontPanel.shared.orderFront(self)
    }

    @objc func scriptFontChanged(_ sender: NSFontManager?) {
        guard let sender, let script = pendingScript else { return }
        let newFont = sender.convert(AppSettings.shared.resultsFont)
        var overrides = AppSettings.shared.scriptFontOverrides
        overrides[script.rawValue] = newFont.fontName
        AppSettings.shared.scriptFontOverrides = overrides
        pendingScript = nil
        reloadScriptOverrides()
    }

    @objc private func removeSelectedOverride() {
        let index = scriptTableView.selectedRow
        guard scriptOverrideRows.indices.contains(index) else { return }
        var overrides = AppSettings.shared.scriptFontOverrides
        overrides.removeValue(forKey: scriptOverrideRows[index].script.rawValue)
        AppSettings.shared.scriptFontOverrides = overrides
        reloadScriptOverrides()
    }
}

extension AppearanceSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { scriptOverrideRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let override = scriptOverrideRows[row]
        let field = NSTextField(labelWithString: "\(override.script.displayName): \(override.fontName)")
        field.font = .systemFont(ofSize: 12)
        return field
    }
}
