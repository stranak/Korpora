import Cocoa
import ManateeKit

/// Content of the "New Concordance" sheet's "New Subcorpus…" popover -
/// restricts a corpus to one structure (e.g. `<doc>`) matching a CQL
/// attribute expression (e.g. `author="Twain"`, no brackets - see
/// `Corpus.createSubcorpus`'s doc comment for why).
final class NewSubcorpusPopoverController: NSViewController {
    var corpusInfo: CorpusInfo?
    var onCreate: ((_ name: String, _ structure: String, _ query: String) -> Void)?

    private let nameField = NSTextField(string: "")
    private let structurePopUp = NSPopUpButton()
    private let queryField = CQLQueryField()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 230))

        let nameLabel = NSTextField(labelWithString: "Name:")
        let structLabel = NSTextField(labelWithString: "Structure:")
        let queryLabel = NSTextField(labelWithString: "Restrict to (e.g. author=\"Twain\"):")
        queryLabel.font = .systemFont(ofSize: 11)

        let structureNames = corpusInfo?.structures.map(\.name) ?? []
        if structureNames.isEmpty {
            structurePopUp.addItem(withTitle: "No structures")
            structurePopUp.isEnabled = false
        } else {
            structurePopUp.addItems(withTitles: structureNames)
        }

        let createButton = NSButton(title: "Create", target: self, action: #selector(createTapped))
        createButton.keyEquivalent = "\r"
        createButton.bezelStyle = .rounded
        createButton.isEnabled = !structureNames.isEmpty
        queryField.onSubmit = { [weak self] in self?.createTapped() }

        let views: [NSView] = [nameLabel, nameField, structLabel, structurePopUp, queryLabel, queryField, createButton]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),

            structLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 12),
            structLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            structurePopUp.centerYAnchor.constraint(equalTo: structLabel.centerYAnchor),
            structurePopUp.leadingAnchor.constraint(equalTo: structLabel.trailingAnchor, constant: 8),

            queryLabel.topAnchor.constraint(equalTo: structLabel.bottomAnchor, constant: 12),
            queryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            queryLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            queryField.topAnchor.constraint(equalTo: queryLabel.bottomAnchor, constant: 6),
            queryField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            queryField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            createButton.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 16),
            createButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            createButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        preferredContentSize = root.frame.size
    }

    @objc private func createTapped() {
        guard let structure = structurePopUp.titleOfSelectedItem, structurePopUp.isEnabled else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let query = queryField.text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !query.isEmpty else { return }
        onCreate?(name, structure, query)
    }
}
