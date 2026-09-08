import Cocoa
import ManateeKit

/// A disposable, re-runnable results window for `ConcordanceDocument.
/// collocations(_:)` - not an `NSDocument`, since this is a snapshot report
/// derived from an existing concordance, not a first-class saved artifact
/// (see docs/project-plan.md's Phase 3 writeup). Closing it just discards
/// the snapshot; re-run via the toolbar's Collocations button anytime.
final class CollocationWindowController: NSWindowController {
    convenience init(spec: CollocationSpec, items: [CollocationItem]) {
        let viewController = CollocationViewController(spec: spec, items: items)
        let window = NSWindow(contentViewController: viewController)
        window.setContentSize(NSSize(width: 480, height: 360))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Collocations: \(spec.attribute)"
        self.init(window: window)
    }
}

private final class CollocationViewController: NSViewController {
    private enum Column: String { case word, freq, cnt, score }

    private let spec: CollocationSpec
    private var items: [CollocationItem]
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    init(spec: CollocationSpec, items: [CollocationItem]) {
        self.spec = spec
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
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
        word.width = 160
        word.sortDescriptorPrototype = NSSortDescriptor(key: Column.word.rawValue, ascending: true)

        let freq = NSTableColumn(identifier: .init(Column.freq.rawValue))
        freq.title = "Freq"
        freq.width = 80
        freq.sortDescriptorPrototype = NSSortDescriptor(key: Column.freq.rawValue, ascending: false)

        let cnt = NSTableColumn(identifier: .init(Column.cnt.rawValue))
        cnt.title = "Co-occurrences"
        cnt.width = 110
        cnt.sortDescriptorPrototype = NSSortDescriptor(key: Column.cnt.rawValue, ascending: false)

        let score = NSTableColumn(identifier: .init(Column.score.rawValue))
        score.title = "Score"
        score.width = 100
        score.sortDescriptorPrototype = NSSortDescriptor(key: Column.score.rawValue, ascending: false)

        for column in [word, freq, cnt, score] {
            tableView.addTableColumn(column)
        }
        // Results already arrive best-scoring first from LiveConcordance.
        // collocations(_:) - reflect that as the table's initial sort state.
        tableView.sortDescriptors = [NSSortDescriptor(key: Column.score.rawValue, ascending: false)]

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
    }
}

extension CollocationViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }) else { return nil }
        let item = items[row]
        let text: String
        switch identifier {
        case .word: text = item.word
        case .freq: text = String(item.freq)
        case .cnt: text = String(item.cnt)
        case .score: text = String(format: "%.3f", item.score)
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        return field
    }

    // A static snapshot, not a live/undoable operation chain like the main
    // KWIC table - a plain in-memory sort + reload is all this needs.
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key, let column = Column(rawValue: key) else { return }
        items.sort { a, b in
            let ascending = descriptor.ascending
            switch column {
            case .word: return ascending ? a.word < b.word : a.word > b.word
            case .freq: return ascending ? a.freq < b.freq : a.freq > b.freq
            case .cnt: return ascending ? a.cnt < b.cnt : a.cnt > b.cnt
            case .score: return ascending ? a.score < b.score : a.score > b.score
            }
        }
        tableView.reloadData()
    }
}
