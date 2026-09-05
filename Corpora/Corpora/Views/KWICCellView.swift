import Cocoa

/// A single Left/Match/Right cell - monospaced, with the matched span in
/// bold accent color, mirroring the KWIC styling from the earlier SwiftUI
/// prototype (`ContentView.KWICRow`).
final class KWICCellView: NSTableCellView {
    enum Style { case plain, highlighted }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isBordered = false
        label.isEditable = false
        label.drawsBackground = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(text: String, alignment: NSTextAlignment, style: Style) {
        wantsLayer = false
        layer?.backgroundColor = nil
        label.stringValue = text
        label.alignment = alignment
        label.lineBreakMode = alignment == .right ? .byTruncatingHead : .byTruncatingTail
        let baseFont = AppSettings.shared.resultsFont
        switch style {
        case .plain:
            label.font = baseFont
            label.textColor = .labelColor
        case .highlighted:
            label.font = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            label.textColor = .controlAccentColor
        }
    }

    /// A small colored badge for the leading "Group" column - table-native
    /// (a narrow tinted column), rather than repainting the whole row.
    func configureGroup(_ group: Int) {
        label.alignment = .center
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        guard group > 0 else {
            label.stringValue = ""
            wantsLayer = false
            layer?.backgroundColor = nil
            return
        }
        label.stringValue = "\(group)"
        label.textColor = .white
        wantsLayer = true
        layer?.backgroundColor = Self.color(forGroup: group).cgColor
        layer?.cornerRadius = 4
    }

    private static func color(forGroup group: Int) -> NSColor {
        let palette: [NSColor] = [
            .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal,
            .systemBlue, .systemPurple, .systemPink, .systemBrown,
        ]
        return palette[(group - 1) % palette.count]
    }
}
