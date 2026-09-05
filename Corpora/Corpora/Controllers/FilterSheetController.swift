import Cocoa
import ManateeKit

/// The sheet behind the toolbar's Filter button - a positive/negative
/// sub-query over a token window around each hit, matching KonText's own
/// filter form (including its -5/5 default window; see `PNFilterSpec`).
final class FilterSheetController: NSViewController {
    var onApply: ((PNFilterSpec) -> Void)?

    private let positiveRadio = NSButton(radioButtonWithTitle: "Keep matching lines", target: nil, action: nil)
    private let negativeRadio = NSButton(radioButtonWithTitle: "Remove matching lines", target: nil, action: nil)
    private let leftField = NSTextField(string: "-5")
    private let rightField = NSTextField(string: "5")
    private let rankPopUp = NSPopUpButton()
    private let includeKwicCheckbox = NSButton(checkboxWithTitle: "Include the match itself", target: nil, action: nil)
    private let queryField = CQLQueryField()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))

        positiveRadio.state = .on
        rankPopUp.addItems(withTitles: ["First match", "Last match"])
        includeKwicCheckbox.state = .on
        queryField.onSubmit = { [weak self] in self?.applyTapped() }

        let title = NSTextField(labelWithString: "Filter Concordance")
        title.font = .boldSystemFont(ofSize: 13)
        let queryLabel = NSTextField(labelWithString: "Query (CQL):")
        let windowLabel = NSTextField(labelWithString: "Window:")
        let toLabel = NSTextField(labelWithString: "to")
        let rankLabel = NSTextField(labelWithString: "Rank:")
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.keyEquivalent = "\u{1b}"
        let applyButton = NSButton(title: "Filter", target: self, action: #selector(applyTapped))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded

        let views: [NSView] = [
            title, positiveRadio, negativeRadio, queryLabel, queryField, windowLabel, leftField, toLabel,
            rightField, rankLabel, rankPopUp, includeKwicCheckbox, cancelButton, applyButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        leftField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        rightField.widthAnchor.constraint(equalToConstant: 50).isActive = true

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            positiveRadio.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            positiveRadio.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            negativeRadio.topAnchor.constraint(equalTo: positiveRadio.bottomAnchor, constant: 6),
            negativeRadio.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            queryLabel.topAnchor.constraint(equalTo: negativeRadio.bottomAnchor, constant: 16),
            queryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            queryField.topAnchor.constraint(equalTo: queryLabel.bottomAnchor, constant: 6),
            queryField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            queryField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            windowLabel.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 16),
            windowLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            leftField.centerYAnchor.constraint(equalTo: windowLabel.centerYAnchor),
            leftField.leadingAnchor.constraint(equalTo: windowLabel.trailingAnchor, constant: 8),
            toLabel.centerYAnchor.constraint(equalTo: windowLabel.centerYAnchor),
            toLabel.leadingAnchor.constraint(equalTo: leftField.trailingAnchor, constant: 6),
            rightField.centerYAnchor.constraint(equalTo: windowLabel.centerYAnchor),
            rightField.leadingAnchor.constraint(equalTo: toLabel.trailingAnchor, constant: 6),

            rankLabel.topAnchor.constraint(equalTo: windowLabel.bottomAnchor, constant: 12),
            rankLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            rankPopUp.centerYAnchor.constraint(equalTo: rankLabel.centerYAnchor),
            rankPopUp.leadingAnchor.constraint(equalTo: rankLabel.trailingAnchor, constant: 8),

            includeKwicCheckbox.topAnchor.constraint(equalTo: rankLabel.bottomAnchor, constant: 12),
            includeKwicCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            applyButton.topAnchor.constraint(greaterThanOrEqualTo: includeKwicCheckbox.bottomAnchor, constant: 16),
            applyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancelButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
        ])

        view = root
        preferredContentSize = NSSize(width: 460, height: 320)
    }

    @objc private func applyTapped() {
        let spec = PNFilterSpec(
            positive: positiveRadio.state == .on,
            leftOffset: Int(leftField.stringValue) ?? -5,
            rightOffset: Int(rightField.stringValue) ?? 5,
            rank: rankPopUp.indexOfSelectedItem == 1 ? .last : .first,
            includeKwic: includeKwicCheckbox.state == .on,
            query: queryField.text)
        onApply?(spec)
        dismiss(self)
    }

    @objc private func cancelTapped() {
        dismiss(self)
    }
}
