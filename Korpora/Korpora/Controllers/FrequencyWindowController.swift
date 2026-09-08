import Cocoa
import ManateeKit

/// A disposable, re-runnable results window for `ConcordanceDocument.
/// frequencyDistribution(_:minFrequency:)` - same non-document rationale as
/// `CollocationWindowController`.
final class FrequencyWindowController: NSWindowController {
    convenience init(criterion: FrequencyCriterion, items: [FrequencyItem]) {
        let viewController = FrequencyViewController(items: items)
        let window = NSWindow(contentViewController: viewController)
        window.setContentSize(NSSize(width: 400, height: 360))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Frequencies: \(criterion.attribute)"
        self.init(window: window)
    }
}

private final class FrequencyViewController: NSViewController {
    private enum Column: String { case word, freq, norm }

    private var items: [FrequencyItem]
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    init(items: [FrequencyItem]) {
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 360))
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self

        let word = NSTableColumn(identifier: .init(Column.word.rawValue))
        word.title = "Word"
        word.width = 180
        word.sortDescriptorPrototype = NSSortDescriptor(key: Column.word.rawValue, ascending: true)

        let freq = NSTableColumn(identifier: .init(Column.freq.rawValue))
        freq.title = "Freq"
        freq.width = 90
        freq.sortDescriptorPrototype = NSSortDescriptor(key: Column.freq.rawValue, ascending: false)

        let norm = NSTableColumn(identifier: .init(Column.norm.rawValue))
        norm.title = "Norm"
        norm.width = 90
        norm.sortDescriptorPrototype = NSSortDescriptor(key: Column.norm.rawValue, ascending: false)

        for column in [word, freq, norm] {
            tableView.addTableColumn(column)
        }
        // Results already arrive frequency-descending from LiveConcordance.
        // frequencyDistribution(_:minFrequency:) - reflect that initially.
        tableView.sortDescriptors = [NSSortDescriptor(key: Column.freq.rawValue, ascending: false)]

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
    }
}

extension FrequencyViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }) else { return nil }
        let item = items[row]
        let text: String
        switch identifier {
        case .word: text = item.word
        case .freq: text = String(item.freq)
        // Blank, not "0", when not applicable (a plain positional-attribute
        // criterion) - "0" would misleadingly read as a real measured value.
        case .norm: text = item.norm.map(String.init) ?? ""
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        return field
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key, let column = Column(rawValue: key) else { return }
        items.sort { a, b in
            let ascending = descriptor.ascending
            switch column {
            case .word: return ascending ? a.word < b.word : a.word > b.word
            case .freq: return ascending ? a.freq < b.freq : a.freq > b.freq
            case .norm: return ascending ? (a.norm ?? 0) < (b.norm ?? 0) : (a.norm ?? 0) > (b.norm ?? 0)
            }
        }
        tableView.reloadData()
    }
}
