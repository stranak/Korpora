import Cocoa
import ManateeKit

/// The sheet behind the toolbar's Collocations button - mirrors KonText's own
/// collocation form (attribute/measure/window/frequency thresholds), same
/// overall shape as `FilterSheetController`. Needs `corpusName` set before
/// presenting so it can populate the attribute picker from the real corpus
/// (see `NewConcordanceSheetController.refreshForSelectedCorpus`, which uses
/// the same `Corpus(name:).info()` call for the same reason).
final class CollocationSheetController: NSViewController {
    var corpusName: String = ""
    var onRun: ((CollocationSpec) -> Void)?

    private static let measures: [AssociationMeasure] = [.logDice, .mutualInformation, .mi3, .tScore, .logLikelihood, .dice]
    private static func displayName(_ measure: AssociationMeasure) -> String {
        switch measure {
        case .logDice: return "logDice"
        case .mutualInformation: return "MI"
        case .mi3: return "MI3"
        case .tScore: return "T-score"
        case .logLikelihood: return "Log-likelihood"
        case .dice: return "Dice"
        }
    }

    private let attributePopUp = NSPopUpButton()
    private let measurePopUp = NSPopUpButton()
    private let leftWindowField = NSTextField(string: "-5")
    private let rightWindowField = NSTextField(string: "5")
    private let minFrequencyField = NSTextField(string: "5")
    private let minCollocateFrequencyField = NSTextField(string: "3")
    private let maxItemsField = NSTextField(string: "50")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))

        let title = NSTextField(labelWithString: "Collocations")
        title.font = .boldSystemFont(ofSize: 13)

        let attributeLabel = NSTextField(labelWithString: "Attribute:")
        measurePopUp.addItems(withTitles: Self.measures.map(Self.displayName))

        let measureLabel = NSTextField(labelWithString: "Measure:")
        let windowLabel = NSTextField(labelWithString: "Window:")
        let toLabel = NSTextField(labelWithString: "to")
        let minFreqLabel = NSTextField(labelWithString: "Min. word frequency:")
        let minCollocateLabel = NSTextField(labelWithString: "Min. collocation frequency:")
        let maxItemsLabel = NSTextField(labelWithString: "Max. items:")

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.keyEquivalent = "\u{1b}"
        let runButton = NSButton(title: "Run", target: self, action: #selector(runTapped))
        runButton.keyEquivalent = "\r"
        runButton.bezelStyle = .rounded

        let views: [NSView] = [
            title, attributeLabel, attributePopUp, measureLabel, measurePopUp,
            windowLabel, leftWindowField, toLabel, rightWindowField,
            minFreqLabel, minFrequencyField, minCollocateLabel, minCollocateFrequencyField,
            maxItemsLabel, maxItemsField, errorLabel, cancelButton, runButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        for field in [leftWindowField, rightWindowField, minFrequencyField, minCollocateFrequencyField, maxItemsField] {
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            attributeLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            attributeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            attributePopUp.centerYAnchor.constraint(equalTo: attributeLabel.centerYAnchor),
            attributePopUp.leadingAnchor.constraint(equalTo: attributeLabel.trailingAnchor, constant: 8),

            measureLabel.topAnchor.constraint(equalTo: attributeLabel.bottomAnchor, constant: 12),
            measureLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            measurePopUp.centerYAnchor.constraint(equalTo: measureLabel.centerYAnchor),
            measurePopUp.leadingAnchor.constraint(equalTo: measureLabel.trailingAnchor, constant: 8),

            windowLabel.topAnchor.constraint(equalTo: measureLabel.bottomAnchor, constant: 12),
            windowLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            leftWindowField.centerYAnchor.constraint(equalTo: windowLabel.centerYAnchor),
            leftWindowField.leadingAnchor.constraint(equalTo: windowLabel.trailingAnchor, constant: 8),
            toLabel.centerYAnchor.constraint(equalTo: windowLabel.centerYAnchor),
            toLabel.leadingAnchor.constraint(equalTo: leftWindowField.trailingAnchor, constant: 6),
            rightWindowField.centerYAnchor.constraint(equalTo: windowLabel.centerYAnchor),
            rightWindowField.leadingAnchor.constraint(equalTo: toLabel.trailingAnchor, constant: 6),

            minFreqLabel.topAnchor.constraint(equalTo: windowLabel.bottomAnchor, constant: 12),
            minFreqLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            minFrequencyField.centerYAnchor.constraint(equalTo: minFreqLabel.centerYAnchor),
            minFrequencyField.leadingAnchor.constraint(equalTo: minFreqLabel.trailingAnchor, constant: 8),

            minCollocateLabel.topAnchor.constraint(equalTo: minFreqLabel.bottomAnchor, constant: 12),
            minCollocateLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            minCollocateFrequencyField.centerYAnchor.constraint(equalTo: minCollocateLabel.centerYAnchor),
            minCollocateFrequencyField.leadingAnchor.constraint(equalTo: minCollocateLabel.trailingAnchor, constant: 8),

            maxItemsLabel.topAnchor.constraint(equalTo: minCollocateLabel.bottomAnchor, constant: 12),
            maxItemsLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            maxItemsField.centerYAnchor.constraint(equalTo: maxItemsLabel.centerYAnchor),
            maxItemsField.leadingAnchor.constraint(equalTo: maxItemsLabel.trailingAnchor, constant: 8),

            errorLabel.topAnchor.constraint(equalTo: maxItemsLabel.bottomAnchor, constant: 12),
            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            runButton.topAnchor.constraint(greaterThanOrEqualTo: errorLabel.bottomAnchor, constant: 16),
            runButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            runButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancelButton.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -8),
        ])

        view = root
        preferredContentSize = NSSize(width: 420, height: 320)

        // Corpus is an actor - even a non-async method call on it needs an
        // async context, so this can't run inline in loadView() (see
        // NewConcordanceSheetController.refreshForSelectedCorpus for the
        // same pattern).
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let corpus = try Corpus(name: corpusName)
                let info = await corpus.info()
                attributePopUp.addItems(withTitles: info.attributes)
            } catch {
                errorLabel.stringValue = "\(error)"
                errorLabel.isHidden = false
            }
        }
    }

    @objc private func runTapped() {
        guard let attribute = attributePopUp.titleOfSelectedItem else { return }
        let measure = Self.measures[measurePopUp.indexOfSelectedItem]
        let spec = CollocationSpec(
            attribute: attribute, measure: measure,
            leftWindow: Int(leftWindowField.stringValue) ?? -5,
            rightWindow: Int(rightWindowField.stringValue) ?? 5,
            minFrequency: Int(minFrequencyField.stringValue) ?? 5,
            minCollocateFrequency: Int(minCollocateFrequencyField.stringValue) ?? 3,
            maxItems: Int(maxItemsField.stringValue) ?? 50)
        onRun?(spec)
        dismiss(self)
    }

    @objc private func cancelTapped() {
        dismiss(self)
    }
}
