import Cocoa
import ManateeKit

/// Content of the toolbar's Attributes popover - which secondary positional
/// attributes (e.g. "lemma", "tag") to show alongside the primary word text
/// in the KWIC/context columns, and how (see `ConcordanceDocument.
/// setAttributeDisplay`, `KWICFormatter`). Inline and hover are independent
/// per attribute (a checkbox pair each, not one mode for the whole popover)
/// - a user may reasonably want e.g. "tag" always visible inline but
/// "lemma" only on hover, at the same time. Attribute names come from the
/// real corpus (same `Corpus(name:).info()` call `CollocationSheetController`
/// already uses to populate its own attribute picker), not free text - a
/// typo'd name would otherwise throw on every subsequent KWIC refetch (see
/// `LiveConcordance.kwicLines`'s doc comment on an unknown attribute name).
final class AttributeDisplayPopoverController: NSViewController {
    var corpusName: String = ""
    /// The primary attribute already shown as each token's main text -
    /// excluded from the row list, since offering it again as a
    /// "secondary" attribute would just duplicate what's already visible.
    var primaryAttribute: String = "word"
    var selectedInlineAttributes: [String] = []
    var selectedTooltipAttributes: [String] = []
    /// Fully-qualified name (e.g. "doc.title") or nil for "None" - see
    /// `ConcordanceDocument.structuralAttributeToShow`. Only one can ever
    /// be shown (there's a single "Doc" column, not one per attribute),
    /// so this is a radio-button choice, not a checklist - see
    /// `populateStructuralRows`.
    var selectedStructuralAttribute: String?
    var onApply: (([String], [String], String?) -> Void)?

    private struct Row {
        let attribute: String
        let inlineCheckbox: NSButton
        let tooltipCheckbox: NSButton
    }

    private let rowsStack = NSStackView()
    private let structuralSectionTitle = NSTextField(labelWithString: "Structural:")
    private let structuralRowsStack = NSStackView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var rows: [Row] = []
    /// `attribute` is nil for the "None" radio button.
    private var structuralRadioButtons: [(attribute: String?, button: NSButton)] = []
    private static let width: CGFloat = 300

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 180))

        let title = NSTextField(labelWithString: "Show attributes:")
        title.font = .boldSystemFont(ofSize: 12)

        let headerRow = NSStackView(views: [
            Self.makeSpacer(), Self.makeColumnHeader("Inline"), Self.makeColumnHeader("On Hover"),
        ])
        headerRow.orientation = .horizontal
        headerRow.spacing = 16

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 4

        structuralSectionTitle.font = .boldSystemFont(ofSize: 12)

        structuralRowsStack.orientation = .vertical
        structuralRowsStack.alignment = .leading
        structuralRowsStack.spacing = 4

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applyTapped))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded

        let views: [NSView] = [
            title, headerRow, rowsStack, structuralSectionTitle, structuralRowsStack, errorLabel, applyButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            headerRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            headerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            rowsStack.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 4),
            rowsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),

            structuralSectionTitle.topAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: 16),
            structuralSectionTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            structuralRowsStack.topAnchor.constraint(equalTo: structuralSectionTitle.bottomAnchor, constant: 6),
            structuralRowsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            structuralRowsStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),

            errorLabel.topAnchor.constraint(equalTo: structuralRowsStack.bottomAnchor, constant: 12),
            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            applyButton.topAnchor.constraint(greaterThanOrEqualTo: errorLabel.bottomAnchor, constant: 16),
            applyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        preferredContentSize = NSSize(width: Self.width, height: 180)

        // Corpus is an actor - even a non-async method call on it needs an
        // async context, so this can't run inline here (see
        // CollocationSheetController.loadView for the same pattern).
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let corpus = try Corpus(name: corpusName)
                let info = await corpus.info()
                populateRows(attributes: info.attributes.filter { $0 != primaryAttribute })
                populateStructuralRows(structures: info.structures)
            } catch {
                errorLabel.stringValue = "\(error)"
                errorLabel.isHidden = false
            }
        }
    }

    private static func makeSpacer() -> NSView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 90).isActive = true
        return spacer
    }

    private static func makeColumnHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        return label
    }

    private func populateRows(attributes: [String]) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        if attributes.isEmpty {
            let label = NSTextField(labelWithString: "No other attributes available.")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            rowsStack.addArrangedSubview(label)
            return
        }
        for attribute in attributes {
            let nameLabel = NSTextField(labelWithString: attribute)
            nameLabel.font = .systemFont(ofSize: 12)
            nameLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true

            let inlineCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            inlineCheckbox.state = selectedInlineAttributes.contains(attribute) ? .on : .off
            inlineCheckbox.widthAnchor.constraint(equalToConstant: 70).isActive = true

            let tooltipCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            tooltipCheckbox.state = selectedTooltipAttributes.contains(attribute) ? .on : .off

            let row = NSStackView(views: [nameLabel, inlineCheckbox, tooltipCheckbox])
            row.orientation = .horizontal
            row.spacing = 16
            rowsStack.addArrangedSubview(row)
            rows.append(Row(attribute: attribute, inlineCheckbox: inlineCheckbox, tooltipCheckbox: tooltipCheckbox))
        }
    }

    /// One radio button per structural attribute (e.g. "doc.title",
    /// "doc.author"), plus "None" - unlike positional attributes (a
    /// checklist, since any number can be shown inline/on hover at once),
    /// only one structural attribute can ever be shown (there's a single
    /// "Doc" column), so this is mutually exclusive by nature. Radio
    /// buttons, not a pop-up, per HIG's guidance on presenting a small set
    /// of mutually exclusive options where showing every choice at once
    /// (rather than hiding them behind a menu) helps people scan them.
    /// Exclusivity is managed explicitly in `structuralRadioTapped(_:)`
    /// rather than relying on AppKit's automatic same-superview radio
    /// grouping - that turned out not to kick in here (found via manual
    /// testing 2026-09-08: every button toggled independently, so more
    /// than one could end up checked), most likely because grouping is
    /// tied to a shared, non-nil target/action, and this passed `nil` for
    /// both.
    private func populateStructuralRows(structures: [StructureInfo]) {
        structuralRowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        structuralRadioButtons = []
        let qualifiedNames = structures.flatMap { structure in
            structure.attributes.map { "\(structure.name).\($0)" }
        }
        if qualifiedNames.isEmpty {
            structuralSectionTitle.isHidden = true
            structuralRowsStack.isHidden = true
        } else {
            structuralSectionTitle.isHidden = false
            structuralRowsStack.isHidden = false
            func addRadioButton(title: String, attribute: String?) {
                let button = NSButton(
                    radioButtonWithTitle: title, target: self, action: #selector(structuralRadioTapped(_:)))
                button.state = selectedStructuralAttribute == attribute ? .on : .off
                structuralRowsStack.addArrangedSubview(button)
                structuralRadioButtons.append((attribute: attribute, button: button))
            }
            addRadioButton(title: "None", attribute: nil)
            for name in qualifiedNames {
                addRadioButton(title: name, attribute: name)
            }
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: view.fittingSize.height)
    }

    /// Manual radio-group exclusivity - see `populateStructuralRows`'s doc
    /// comment on why this isn't left to AppKit's automatic grouping.
    @objc private func structuralRadioTapped(_ sender: NSButton) {
        for (_, button) in structuralRadioButtons {
            button.state = (button === sender) ? .on : .off
        }
    }

    @objc private func applyTapped() {
        let inline = rows.filter { $0.inlineCheckbox.state == .on }.map(\.attribute)
        let tooltip = rows.filter { $0.tooltipCheckbox.state == .on }.map(\.attribute)
        let structural = structuralRadioButtons.first { $0.button.state == .on }?.attribute
        onApply?(inline, tooltip, structural)
    }
}
