import Cocoa

/// Content of the toolbar's Sample popover - an absolute line count, matching
/// KonText's own sample form (no percentage option; see
/// `LiveConcordance.sample`'s doc comment).
final class SamplePopoverController: NSViewController {
    var onApply: ((Int) -> Void)?

    private let linesField = NSTextField(string: "50")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 90))

        let label = NSTextField(labelWithString: "Lines:")
        let applyButton = NSButton(title: "Sample", target: self, action: #selector(applyTapped))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded

        for v in [label, linesField, applyButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        linesField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            linesField.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            linesField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),

            applyButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            applyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        preferredContentSize = root.frame.size
    }

    @objc private func applyTapped() {
        onApply?(Int(linesField.stringValue) ?? 50)
    }
}
