import Cocoa
import ManateeKit

/// Content of the toolbar's Sort popover - a single sort level (multi-level
/// sort is in the model already (see `SortCriteria`), but isn't worth a UI
/// for until someone actually needs it).
final class SortPopoverController: NSViewController {
    var onApply: ((SortCriteria) -> Void)?

    private let attributeField = NSTextField(string: "word")
    private let anchorPopUp = NSPopUpButton()
    private let spanField = NSTextField(string: "5")
    private let caseInsensitiveCheckbox = NSButton(checkboxWithTitle: "Ignore case", target: nil, action: nil)
    private let reverseCheckbox = NSButton(checkboxWithTitle: "Reverse", target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 190))

        anchorPopUp.addItems(withTitles: ["Left", "Match", "Right"])
        anchorPopUp.selectItem(at: 1)

        let attrLabel = NSTextField(labelWithString: "Attribute:")
        let anchorLabel = NSTextField(labelWithString: "Anchor:")
        let spanLabel = NSTextField(labelWithString: "Span:")
        let applyButton = NSButton(title: "Sort", target: self, action: #selector(applyTapped))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded

        let views: [NSView] = [
            attrLabel, attributeField, anchorLabel, anchorPopUp, spanLabel, spanField,
            caseInsensitiveCheckbox, reverseCheckbox, applyButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        attributeField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        spanField.widthAnchor.constraint(equalToConstant: 50).isActive = true

        NSLayoutConstraint.activate([
            attrLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            attrLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            attributeField.centerYAnchor.constraint(equalTo: attrLabel.centerYAnchor),
            attributeField.leadingAnchor.constraint(equalTo: attrLabel.trailingAnchor, constant: 8),

            anchorLabel.topAnchor.constraint(equalTo: attrLabel.bottomAnchor, constant: 12),
            anchorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            anchorPopUp.centerYAnchor.constraint(equalTo: anchorLabel.centerYAnchor),
            anchorPopUp.leadingAnchor.constraint(equalTo: anchorLabel.trailingAnchor, constant: 8),

            spanLabel.topAnchor.constraint(equalTo: anchorLabel.bottomAnchor, constant: 12),
            spanLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            spanField.centerYAnchor.constraint(equalTo: spanLabel.centerYAnchor),
            spanField.leadingAnchor.constraint(equalTo: spanLabel.trailingAnchor, constant: 8),

            caseInsensitiveCheckbox.topAnchor.constraint(equalTo: spanLabel.bottomAnchor, constant: 12),
            caseInsensitiveCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            reverseCheckbox.topAnchor.constraint(equalTo: caseInsensitiveCheckbox.bottomAnchor, constant: 8),
            reverseCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            applyButton.topAnchor.constraint(equalTo: reverseCheckbox.bottomAnchor, constant: 16),
            applyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        preferredContentSize = root.frame.size
    }

    @objc private func applyTapped() {
        let anchor: SortAnchor
        switch anchorPopUp.indexOfSelectedItem {
        case 0: anchor = .left
        case 2: anchor = .right
        default: anchor = .kwic
        }
        let level = SortLevel(
            attribute: attributeField.stringValue.isEmpty ? "word" : attributeField.stringValue,
            anchor: anchor,
            span: Int(spanField.stringValue) ?? 5,
            caseInsensitive: caseInsensitiveCheckbox.state == .on,
            reverse: reverseCheckbox.state == .on)
        onApply?(SortCriteria(level))
    }
}
