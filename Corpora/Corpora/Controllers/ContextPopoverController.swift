import Cocoa

/// Content of the toolbar's Context popover - how many tokens of left/right
/// context each KWIC line shows (see `ConcordanceDocument.setContext`).
/// Unlike Sort/Filter/Sample, the Context button never disables when line
/// groups exist - it's a display setting, not a corpus operation.
final class ContextPopoverController: NSViewController {
    var onApply: ((Int, Int) -> Void)?

    private let leftField: NSTextField
    private let rightField: NSTextField

    init(left: Int, right: Int) {
        leftField = NSTextField(string: String(left))
        rightField = NSTextField(string: String(right))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 90))

        let leftLabel = NSTextField(labelWithString: "Left:")
        let rightLabel = NSTextField(labelWithString: "Right:")
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applyTapped))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded

        for v in [leftLabel, leftField, rightLabel, rightField, applyButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        leftField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        rightField.widthAnchor.constraint(equalToConstant: 50).isActive = true

        NSLayoutConstraint.activate([
            leftLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            leftLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            leftField.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),
            leftField.leadingAnchor.constraint(equalTo: leftLabel.trailingAnchor, constant: 8),

            rightLabel.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),
            rightLabel.leadingAnchor.constraint(equalTo: leftField.trailingAnchor, constant: 16),
            rightField.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),
            rightField.leadingAnchor.constraint(equalTo: rightLabel.trailingAnchor, constant: 8),

            applyButton.topAnchor.constraint(equalTo: leftLabel.bottomAnchor, constant: 16),
            applyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        preferredContentSize = root.frame.size
    }

    @objc private func applyTapped() {
        onApply?(max(Int(leftField.stringValue) ?? 0, 0), max(Int(rightField.stringValue) ?? 0, 0))
    }
}
