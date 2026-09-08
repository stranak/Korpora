import Cocoa

/// Global defaults for **brand-new** concordance documents - not
/// per-document overrides, which stay on the concordance window's own
/// toolbar popovers (Context, the KWIC/Sentence switch). Changing a value
/// here never affects an already-open window, only the next one created.
final class ConcordanceSettingsViewController: NSViewController {
    private let leftContextField = NSTextField(string: "")
    private let rightContextField = NSTextField(string: "")
    private let viewModeControl = NSSegmentedControl(
        labels: ["KWIC", "Sentence"], trackingMode: .selectOne, target: nil, action: nil)
    private let extendedContextField = NSTextField(string: "")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))

        let contextLabel = NSTextField(labelWithString: "Default context width:")
        let leftLabel = NSTextField(labelWithString: "Left:")
        let rightLabel = NSTextField(labelWithString: "Right:")
        let viewModeLabel = NSTextField(labelWithString: "Default view:")
        let extendedLabel = NSTextField(labelWithString: "Extended context tokens:")
        extendedLabel.font = .systemFont(ofSize: 11)
        extendedLabel.textColor = .secondaryLabelColor

        leftContextField.delegate = self
        rightContextField.delegate = self
        extendedContextField.delegate = self
        viewModeControl.segmentStyle = .texturedRounded
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)

        let settings = AppSettings.shared
        leftContextField.stringValue = String(settings.defaultLeftContext)
        rightContextField.stringValue = String(settings.defaultRightContext)
        extendedContextField.stringValue = String(settings.defaultExtendedContextTokens)
        viewModeControl.selectedSegment = settings.defaultViewMode == .sentence ? 1 : 0

        let views: [NSView] = [
            contextLabel, leftLabel, leftContextField, rightLabel, rightContextField,
            viewModeLabel, viewModeControl, extendedLabel, extendedContextField,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        leftContextField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        rightContextField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        extendedContextField.widthAnchor.constraint(equalToConstant: 50).isActive = true

        NSLayoutConstraint.activate([
            contextLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            contextLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            leftLabel.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 10),
            leftLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            leftContextField.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),
            leftContextField.leadingAnchor.constraint(equalTo: leftLabel.trailingAnchor, constant: 8),
            rightLabel.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),
            rightLabel.leadingAnchor.constraint(equalTo: leftContextField.trailingAnchor, constant: 16),
            rightContextField.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),
            rightContextField.leadingAnchor.constraint(equalTo: rightLabel.trailingAnchor, constant: 8),

            viewModeLabel.topAnchor.constraint(equalTo: leftLabel.bottomAnchor, constant: 20),
            viewModeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            viewModeControl.centerYAnchor.constraint(equalTo: viewModeLabel.centerYAnchor),
            viewModeControl.leadingAnchor.constraint(equalTo: viewModeLabel.trailingAnchor, constant: 8),

            extendedLabel.topAnchor.constraint(equalTo: viewModeLabel.bottomAnchor, constant: 20),
            extendedLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            extendedContextField.centerYAnchor.constraint(equalTo: extendedLabel.centerYAnchor),
            extendedContextField.leadingAnchor.constraint(equalTo: extendedLabel.trailingAnchor, constant: 8),
        ])

        view = root
        preferredContentSize = NSSize(width: 420, height: 180)
    }

    @objc private func viewModeChanged() {
        AppSettings.shared.defaultViewMode = viewModeControl.selectedSegment == 1 ? .sentence : .kwic
    }
}

extension ConcordanceSettingsViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let settings = AppSettings.shared
        switch field {
        case leftContextField:
            settings.defaultLeftContext = max(Int(field.stringValue) ?? settings.defaultLeftContext, 0)
        case rightContextField:
            settings.defaultRightContext = max(Int(field.stringValue) ?? settings.defaultRightContext, 0)
        case extendedContextField:
            settings.defaultExtendedContextTokens = max(Int(field.stringValue) ?? settings.defaultExtendedContextTokens, 1)
        default:
            break
        }
    }
}
