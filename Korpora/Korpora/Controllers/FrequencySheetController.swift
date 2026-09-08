import Cocoa
import ManateeKit

/// The sheet behind the toolbar's Frequencies button - an attribute to group
/// by (positional, e.g. "lemma", or structural, written "struct.attr", e.g.
/// "doc.author"), a context offset, and a minimum-frequency cutoff. Same
/// shape as `CollocationSheetController`; needs `corpusName` set before
/// presenting to populate the attribute picker.
final class FrequencySheetController: NSViewController {
    var corpusName: String = ""
    var onRun: ((FrequencyCriterion, Int) -> Void)?

    private let attributePopUp = NSPopUpButton()
    private let contextOffsetField = NSTextField(string: "0")
    private let caseInsensitiveCheckbox = NSButton(checkboxWithTitle: "Ignore case", target: nil, action: nil)
    private let minFrequencyField = NSTextField(string: "1")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))

        let title = NSTextField(labelWithString: "Frequency Distribution")
        title.font = .boldSystemFont(ofSize: 13)

        let attributeLabel = NSTextField(labelWithString: "Attribute:")
        let contextLabel = NSTextField(labelWithString: "Context offset:")
        let minFreqLabel = NSTextField(labelWithString: "Min. frequency:")

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.keyEquivalent = "\u{1b}"
        let runButton = NSButton(title: "Run", target: self, action: #selector(runTapped))
        runButton.keyEquivalent = "\r"
        runButton.bezelStyle = .rounded

        let views: [NSView] = [
            title, attributeLabel, attributePopUp, contextLabel, contextOffsetField,
            caseInsensitiveCheckbox, minFreqLabel, minFrequencyField, errorLabel, cancelButton, runButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        contextOffsetField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        minFrequencyField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            attributeLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            attributeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            attributePopUp.centerYAnchor.constraint(equalTo: attributeLabel.centerYAnchor),
            attributePopUp.leadingAnchor.constraint(equalTo: attributeLabel.trailingAnchor, constant: 8),

            contextLabel.topAnchor.constraint(equalTo: attributeLabel.bottomAnchor, constant: 12),
            contextLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            contextOffsetField.centerYAnchor.constraint(equalTo: contextLabel.centerYAnchor),
            contextOffsetField.leadingAnchor.constraint(equalTo: contextLabel.trailingAnchor, constant: 8),

            caseInsensitiveCheckbox.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 12),
            caseInsensitiveCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            minFreqLabel.topAnchor.constraint(equalTo: caseInsensitiveCheckbox.bottomAnchor, constant: 12),
            minFreqLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            minFrequencyField.centerYAnchor.constraint(equalTo: minFreqLabel.centerYAnchor),
            minFrequencyField.leadingAnchor.constraint(equalTo: minFreqLabel.trailingAnchor, constant: 8),

            errorLabel.topAnchor.constraint(equalTo: minFreqLabel.bottomAnchor, constant: 12),
            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            runButton.topAnchor.constraint(greaterThanOrEqualTo: errorLabel.bottomAnchor, constant: 16),
            runButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            runButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancelButton.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -8),
        ])

        view = root
        preferredContentSize = NSSize(width: 420, height: 240)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let corpus = try Corpus(name: corpusName)
                let info = await corpus.info()
                var attributes = info.attributes
                for structure in info.structures {
                    attributes += structure.attributes.map { "\(structure.name).\($0)" }
                }
                attributePopUp.addItems(withTitles: attributes)
            } catch {
                errorLabel.stringValue = "\(error)"
                errorLabel.isHidden = false
            }
        }
    }

    @objc private func runTapped() {
        guard let attribute = attributePopUp.titleOfSelectedItem else { return }
        let criterion = FrequencyCriterion(
            attribute: attribute,
            contextOffset: Int(contextOffsetField.stringValue) ?? 0,
            caseInsensitive: caseInsensitiveCheckbox.state == .on)
        let minFrequency = Int(minFrequencyField.stringValue) ?? 1
        onRun?(criterion, minFrequency)
        dismiss(self)
    }

    @objc private func cancelTapped() {
        dismiss(self)
    }
}
