import Cocoa

/// A view that can put an explanatory header (corpus, query, settings) at the
/// top of each printed page. `WindowPrinting.run` sets the lines; the view
/// draws them from `drawPageBorder` via `PrintHeader.draw`, only when the
/// user has the header switched on in the print panel.
protocol PrintHeaderDrawing: NSView {
    var printHeaderLines: [NSAttributedString] { get set }
}

enum PrintHeader {
    static let defaultsKey = "printHeader"
    static let lineHeight: CGFloat = 16

    /// On unless the user turned it off in the print panel.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Top margin that leaves room for `lineCount` header lines.
    static func margin(forLines lineCount: Int) -> CGFloat {
        CGFloat(lineCount) * lineHeight + 22
    }

    /// Plain-text lines in the app's header style: the first is the heading.
    static func attributed(_ lines: [String]) -> [NSAttributedString] {
        lines.enumerated().map { index, line in
            NSAttributedString(string: line, attributes: [
                .font: index == 0 ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 11),
                .foregroundColor: index == 0 ? NSColor.black : NSColor.darkGray,
            ])
        }
    }

    /// Draws `lines` at the top of a page; the caller is `drawPageBorder`.
    static func draw(_ lines: [NSAttributedString], borderSize: NSSize) {
        // AppKit can invoke `drawPageBorder` during a page-count/preview pass
        // with no drawing context yet (see SortableTableView's history).
        guard isEnabled, NSGraphicsContext.current != nil else { return }
        var y = borderSize.height - lineHeight
        for line in lines {
            line.draw(with: NSRect(x: 0, y: y, width: borderSize.width, height: lineHeight),
                      options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            y -= lineHeight
        }
    }
}

/// The print panel's extra option: whether to print the header.
private final class PrintHeaderAccessory: NSViewController, NSPrintPanelAccessorizing {
    private let printInfo: NSPrintInfo
    private let lineCount: Int
    private let normalMargin: CGFloat

    @objc dynamic var includeHeader: Bool {
        didSet {
            PrintHeader.isEnabled = includeHeader
            printInfo.topMargin = includeHeader ? PrintHeader.margin(forLines: lineCount) : normalMargin
        }
    }

    init(printInfo: NSPrintInfo, lineCount: Int, normalMargin: CGFloat) {
        self.printInfo = printInfo
        self.lineCount = lineCount
        self.normalMargin = normalMargin
        includeHeader = PrintHeader.isEnabled
        super.init(nibName: nil, bundle: nil)
        title = "Header"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let box = NSButton(checkboxWithTitle: "Print header with corpus, query and settings",
                           target: nil, action: nil)
        box.bind(.value, to: self, withKeyPath: "includeHeader", options: nil)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        box.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            box.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Header", .itemDescription: includeHeader ? "On" : "Off"]]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { ["includeHeader"] }
}

/// File > Print… for every results window. The menu item targets
/// `printWindowContents(_:)` through the responder chain, and is enabled only
/// when the key window's controller implements it - the concordance window
/// and each auxiliary window (Collocations, Frequencies, Dispersion, Extended
/// Context) does.
enum WindowPrinting {
    /// Runs the standard print panel (which also offers Save as PDF) for `view`,
    /// as a sheet on `window`. `header` describes what is printed; the panel
    /// has a checkbox to leave it out (on by default).
    @MainActor
    static func run(_ view: NSView, jobTitle: String, header: [NSAttributedString] = [], in window: NSWindow?) {
        let operation = NSPrintOperation(view: view)
        operation.jobTitle = jobTitle
        operation.printInfo.horizontalPagination = .fit
        operation.printInfo.verticalPagination = .automatic
        operation.printInfo.isVerticallyCentered = false
        if !header.isEmpty, let drawing = view as? PrintHeaderDrawing {
            drawing.printHeaderLines = header
            let normal = operation.printInfo.topMargin
            operation.printInfo.topMargin = PrintHeader.isEnabled ? PrintHeader.margin(forLines: header.count) : normal
            operation.printPanel.addAccessoryController(
                PrintHeaderAccessory(printInfo: operation.printInfo, lineCount: header.count, normalMargin: normal))
        }
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

extension TableChartContainerView {
    /// What File > Print… prints: the chart when it's showing, else the whole table.
    var printableView: NSView {
        switch mode {
        case .chart: chart
        case .table: table.documentView ?? table
        }
    }

    /// The header lines for the current mode: the window's own (corpus, query,
    /// settings), plus for a chart how it was cut.
    func printHeader(_ lines: [String]) -> [NSAttributedString] {
        var lines = lines
        if mode == .chart, !noteLabel.stringValue.isEmpty {
            lines.append("Chart: \(noteLabel.stringValue)")
        }
        return PrintHeader.attributed(lines)
    }
}

/// A text view for printing a passage with the header on its pages.
final class PrintableTextView: NSTextView, PrintHeaderDrawing {
    var printHeaderLines: [NSAttributedString] = []

    override func drawPageBorder(with borderSize: NSSize) {
        super.drawPageBorder(with: borderSize)
        PrintHeader.draw(printHeaderLines, borderSize: borderSize)
    }

    /// A text view of `text`, laid out `width` points wide and as tall as it needs.
    static func laidOut(_ text: NSAttributedString, width: CGFloat) -> PrintableTextView {
        let view = PrintableTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: width, height: ceil(layout.usedRect(for: container).height) + 8))
        }
        return view
    }
}
