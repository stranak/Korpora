import Cocoa
import ManateeKit

/// Content of the "New Concordance" sheet's "New Subcorpus…" popover -
/// restricts a corpus to the instances of one structure (e.g. `<doc>`)
/// whose attributes match (docs/project-plan.md, 6.9).
///
/// Like KonText's Text Types, the usual way is to tick values: choose an
/// attribute, tick the values wanted (several values of one attribute are
/// alternatives, values of different attributes all have to hold). Those
/// picks become the CQL restriction `Corpus.createSubcorpus` takes, shown
/// as they're made. "CQL expression" mode is the older way, typing the
/// restriction (e.g. `author="Twain"`, no brackets - see
/// `Corpus.createSubcorpus`'s doc comment for why), for anything the lists
/// can't say: ranges, regular expressions, negation.
final class NewSubcorpusPopoverController: NSViewController {
    var corpusInfo: CorpusInfo?
    /// The corpus to read values from. Without it the values list reports
    /// that it can't, and CQL mode still works.
    var corpusName: String?
    var onCreate: ((_ name: String, _ structure: String, _ query: String) -> Void)?
    /// Replaces the engine as the source of values (tests).
    var loaders: SubcorpusValuePickerModel.Loaders?

    private enum Mode: Int { case values, cql }

    private(set) var model: SubcorpusValuePickerModel!

    let nameField = NSTextField(string: "")
    private let structurePopUp = NSPopUpButton()
    let createButton = NSButton(title: "Create", target: nil, action: nil)

    let valuesContainer = NSView()
    private let attributePopUp = NSPopUpButton()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let previewLabel = NSTextField(wrappingLabelWithString: "")

    let cqlContainer = NSView()
    let queryField = CQLQueryField()
    let modeControl = NSSegmentedControl(
        labels: ["Choose values", "CQL expression"], trackingMode: .selectOne, target: nil, action: nil)

    private var mode: Mode = .values

    // MARK: View

    override func loadView() {
        let info = corpusInfo ?? CorpusInfo(name: "", sizeTokens: 0, attributes: [], structures: [])
        model = SubcorpusValuePickerModel(info: info, loaders: loaders ?? makeLoaders())

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 440))

        let nameLabel = NSTextField(labelWithString: "Name:")
        let structLabel = NSTextField(labelWithString: "Structure:")

        if model.structures.isEmpty {
            structurePopUp.addItem(withTitle: "No structures")
            structurePopUp.isEnabled = false
        } else {
            structurePopUp.addItems(withTitles: model.structures)
        }
        structurePopUp.target = self
        structurePopUp.action = #selector(structureChanged)

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = Mode.values.rawValue

        createButton.target = self
        createButton.action = #selector(createTapped)
        createButton.keyEquivalent = "\r"
        createButton.bezelStyle = .rounded
        queryField.onSubmit = { [weak self] in self?.createTapped() }
        nameField.target = self
        nameField.action = #selector(nameEdited)
        nameField.delegate = self

        buildValuesContainer()
        buildCQLContainer()

        let views: [NSView] = [
            nameLabel, nameField, structLabel, structurePopUp, modeControl,
            valuesContainer, cqlContainer, createButton,
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        nameField.widthAnchor.constraint(equalToConstant: 180).isActive = true

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),

            structLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 12),
            structLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            structurePopUp.centerYAnchor.constraint(equalTo: structLabel.centerYAnchor),
            structurePopUp.leadingAnchor.constraint(equalTo: structLabel.trailingAnchor, constant: 8),

            modeControl.topAnchor.constraint(equalTo: structLabel.bottomAnchor, constant: 14),
            modeControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            valuesContainer.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12),
            valuesContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            valuesContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            valuesContainer.bottomAnchor.constraint(equalTo: createButton.topAnchor, constant: -14),

            cqlContainer.topAnchor.constraint(equalTo: valuesContainer.topAnchor),
            cqlContainer.leadingAnchor.constraint(equalTo: valuesContainer.leadingAnchor),
            cqlContainer.trailingAnchor.constraint(equalTo: valuesContainer.trailingAnchor),
            cqlContainer.bottomAnchor.constraint(equalTo: valuesContainer.bottomAnchor),

            createButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            createButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        preferredContentSize = root.frame.size
    }

    private func buildValuesContainer() {
        attributePopUp.target = self
        attributePopUp.action = #selector(attributeChanged)
        fillAttributePopUp()

        searchField.placeholderString = "Search values"
        searchField.target = self
        searchField.action = #selector(searchChanged)

        let column = NSTableColumn(identifier: .init("value"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.controlSize = .small
        clearButton.bezelStyle = .rounded

        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.maximumNumberOfLines = 2
        previewLabel.lineBreakMode = .byTruncatingTail

        let views: [NSView] = [attributePopUp, searchField, scrollView, statusLabel, clearButton, previewLabel]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            valuesContainer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            attributePopUp.topAnchor.constraint(equalTo: valuesContainer.topAnchor),
            attributePopUp.leadingAnchor.constraint(equalTo: valuesContainer.leadingAnchor),
            searchField.centerYAnchor.constraint(equalTo: attributePopUp.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: attributePopUp.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: valuesContainer.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: attributePopUp.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: valuesContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: valuesContainer.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: valuesContainer.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: valuesContainer.trailingAnchor),

            previewLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            previewLabel.leadingAnchor.constraint(equalTo: valuesContainer.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: valuesContainer.trailingAnchor),
            previewLabel.bottomAnchor.constraint(equalTo: valuesContainer.bottomAnchor),
            previewLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
    }

    private func buildCQLContainer() {
        let label = NSTextField(wrappingLabelWithString:
            "Restrict to (e.g. author=\"Twain\"). Use | and & to combine, and the "
            + "structure's own attribute names:")
        label.font = .systemFont(ofSize: 11)
        cqlContainer.addSubview(label)
        cqlContainer.addSubview(queryField)
        for view in [label, queryField] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: cqlContainer.topAnchor),
            label.leadingAnchor.constraint(equalTo: cqlContainer.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: cqlContainer.trailingAnchor),
            queryField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            queryField.leadingAnchor.constraint(equalTo: cqlContainer.leadingAnchor),
            queryField.trailingAnchor.constraint(equalTo: cqlContainer.trailingAnchor),
        ])
        cqlContainer.isHidden = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if model.attribute == nil {
            // Nothing to pick from (no structure, or one without attributes):
            // start where the user can still type a restriction.
            mode = .cql
            modeControl.selectedSegment = Mode.cql.rawValue
            applyMode()
        }
        refresh()
        loadValues()
    }

    // MARK: Model plumbing

    private func makeLoaders() -> SubcorpusValuePickerModel.Loaders {
        let corpus = corpusName.flatMap { try? Corpus(name: $0) }
        return .init(
            values: { attribute, limit in
                guard let corpus else { throw PickerError.corpusUnavailable }
                return try await corpus.topAttributeValues(attribute: attribute, limit: limit)
                    .map { .init(value: $0.value, count: $0.frequency) }
            },
            search: { attribute, text, limit in
                guard let corpus else { throw PickerError.corpusUnavailable }
                return try await corpus.topAttributeValues(
                    attribute: attribute, matching: SubcorpusRestriction.containsPattern(text),
                    ignoreCase: true, limit: limit)
                    .map { .init(value: $0.value, count: $0.frequency) }
            })
    }

    private enum PickerError: Error, CustomStringConvertible {
        case corpusUnavailable
        var description: String { "Couldn\u{2019}t open the corpus to read its values." }
    }

    private func fillAttributePopUp() {
        attributePopUp.removeAllItems()
        if model.attributes.isEmpty {
            attributePopUp.addItem(withTitle: "No attributes")
            attributePopUp.isEnabled = false
        } else {
            attributePopUp.addItems(withTitles: model.attributes)
            attributePopUp.selectItem(withTitle: model.attribute ?? "")
            attributePopUp.isEnabled = true
        }
        searchField.isEnabled = !model.attributes.isEmpty
    }

    /// Redraws everything that depends on the model.
    private func refresh() {
        tableView.reloadData()
        if let error = model.loadError {
            statusLabel.stringValue = error
        } else if model.attribute == nil {
            statusLabel.stringValue = "This structure has no attributes to pick values from; use a CQL expression."
        } else if model.isLoading {
            statusLabel.stringValue = "Loading values\u{2026}"
        } else {
            var parts: [String] = []
            let searching = !searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            if model.isTruncated {
                parts.append("The \(model.rows.count) most frequent values; search to find others")
            } else {
                parts.append("\(model.rows.count) value\(model.rows.count == 1 ? "" : "s")"
                    + (searching ? " match" : ""))
            }
            if model.selectedCount > 0 { parts.append("\(model.selectedCount) selected") }
            statusLabel.stringValue = parts.joined(separator: " \u{00B7} ")
        }
        clearButton.isEnabled = model.selectedCount > 0
        let query = model.restriction.query
        previewLabel.stringValue = query.isEmpty ? "Tick values to build the restriction." : query
        previewLabel.toolTip = query.isEmpty ? nil : query
        updateCreateEnabled()
    }

    private func currentQuery() -> String {
        switch mode {
        case .values: return model.restriction.query
        case .cql: return queryField.text.trimmingCharacters(in: .whitespaces)
        }
    }

    private func updateCreateEnabled() {
        let hasName = !nameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        createButton.isEnabled = !model.structures.isEmpty && hasName && !currentQuery().isEmpty
    }

    private func applyMode() {
        valuesContainer.isHidden = mode != .values
        cqlContainer.isHidden = mode != .cql
    }

    // MARK: Actions

    @objc private func structureChanged() {
        guard let name = structurePopUp.titleOfSelectedItem else { return }
        searchField.stringValue = ""
        model.selectStructure(name)
        fillAttributePopUp()
        if model.attribute == nil, mode == .values {
            mode = .cql
            modeControl.selectedSegment = Mode.cql.rawValue
            applyMode()
        }
        refresh()
        loadValues()
    }

    @objc private func attributeChanged() {
        guard let name = attributePopUp.titleOfSelectedItem else { return }
        searchField.stringValue = ""
        model.selectAttribute(name)
        refresh()
        loadValues()
    }

    private func loadValues() {
        Task {
            await model.reload()
            refresh()
        }
    }

    @objc private func searchChanged() {
        let text = searchField.stringValue
        Task {
            await model.search(text)
            refresh()
        }
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard model.rows.indices.contains(sender.tag) else { return }
        model.toggle(model.rows[sender.tag].value)
        refresh()
    }

    @objc private func clearTapped() {
        model.clearSelection()
        refresh()
    }

    @objc private func modeChanged() {
        mode = Mode(rawValue: modeControl.selectedSegment) ?? .values
        // Choosing values and then wanting to tweak them: start the CQL field
        // from what was picked, unless something is already typed there.
        if mode == .cql, queryField.text.trimmingCharacters(in: .whitespaces).isEmpty {
            queryField.text = model.restriction.query
        }
        applyMode()
        updateCreateEnabled()
    }

    @objc private func nameEdited() {
        updateCreateEnabled()
    }

    @objc private func createTapped() {
        guard let structure = structurePopUp.titleOfSelectedItem, structurePopUp.isEnabled else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let query = currentQuery()
        guard !name.isEmpty, !query.isEmpty else { return }
        onCreate?(name, structure, query)
    }
}

extension NewSubcorpusPopoverController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === nameField { updateCreateEnabled() }
    }
}

extension NewSubcorpusPopoverController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { model?.rows.count ?? 0 }

    /// A checkbox with the value, and how often it occurs on the right (for a
    /// structure attribute: how many <doc>s have it).
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = model.rows[row]
        let checkbox = NSButton(checkboxWithTitle: entry.value.isEmpty ? "(empty)" : entry.value,
                                target: self, action: #selector(checkboxToggled(_:)))
        checkbox.tag = row
        checkbox.state = model.isSelected(entry.value) ? .on : .off
        checkbox.lineBreakMode = .byTruncatingMiddle
        checkbox.toolTip = entry.value
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let count = NSTextField(labelWithString: Self.countFormatter.string(from: NSNumber(value: entry.count)) ?? "\(entry.count)")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.toolTip = "\(entry.count) \(model.structure) with this value"

        let cell = NSView()
        for view in [checkbox, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: checkbox.trailingAnchor, constant: 8),
            count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
