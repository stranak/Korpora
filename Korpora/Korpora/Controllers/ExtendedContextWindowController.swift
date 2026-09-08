import Cocoa
import ManateeKit

/// KonText's own "concordance detail" view (Phase 6.6): much wider context
/// than the table row shows, for one specific hit, with the match itself
/// bolded/accent-colored so it stays easy to find in a long passage.
///
/// A plain non-modal window (`show(_:)` on `ConcordanceViewController`'s
/// existing disposable-auxiliary-window pattern - same as Collocations/
/// Frequency), not a sheet - a sheet can only ever have one open per
/// parent window, which can't support "more than one Extended Context
/// visible at once" (`AppSettings.allowMultipleExtendedContexts`). Shows
/// which hit it's for (corpus/document/sentence - see
/// `ConcordanceDocument.ExtendedContextInfo`) since, once several of
/// these can be open side by side, nothing else on screen says which
/// window belongs to which line.
final class ExtendedContextWindowController: NSWindowController {
    convenience init(info: ConcordanceDocument.ExtendedContextInfo, before: String, match: String, after: String) {
        let viewController = ExtendedContextDetailViewController(info: info, before: before, match: match, after: after)
        let window = NSWindow(contentViewController: viewController)
        window.setContentSize(NSSize(width: 520, height: 340))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Extended Context"
        self.init(window: window)
    }
}

private final class ExtendedContextDetailViewController: NSViewController {
    private let info: ConcordanceDocument.ExtendedContextInfo
    private let attributedText: NSAttributedString

    init(info: ConcordanceDocument.ExtendedContextInfo, before: String, match: String, after: String) {
        self.info = info
        attributedText = Self.makeAttributedString(before: before, match: match, after: after)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2
        for line in info.headerLines {
            let label = NSTextField(labelWithString: line)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            headerStack.addArrangedSubview(label)
        }

        // `.scrollableTextView()` - not a hand-assembled NSScrollView +
        // NSTextView pair - already wires up wrapping/resizing correctly
        // for a plain "scrollable block of text" use like this one.
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textStorage?.setAttributedString(attributedText)
        scrollView.borderType = .bezelBorder

        let views: [NSView] = [headerStack, scrollView]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        preferredContentSize = NSSize(width: 520, height: 340)
    }

    private static func makeAttributedString(before: String, match: String, after: String) -> NSAttributedString {
        let font = AppSettings.shared.resultsFont
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let result = NSMutableAttributedString()
        if !before.isEmpty {
            result.append(NSAttributedString(
                string: before + " ", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        result.append(NSAttributedString(
            string: match, attributes: [.font: boldFont, .foregroundColor: NSColor.controlAccentColor]))
        if !after.isEmpty {
            result.append(NSAttributedString(
                string: " " + after, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        return result
    }
}
