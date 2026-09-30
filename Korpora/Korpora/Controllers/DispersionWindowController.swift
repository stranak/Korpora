import Cocoa

/// Where the hits of the current search fall across the corpus
/// (`DispersionView`). A disposable snapshot window like Collocations and
/// Frequencies: re-run it from the toolbar to refresh it.
final class DispersionWindowController: NSWindowController {
    convenience init(query: String, distribution: HitDistribution, context: [String] = []) {
        let viewController = DispersionViewController(distribution: distribution, context: context)
        let window = NSWindow(contentViewController: viewController)
        window.setContentSize(NSSize(width: 640, height: 340))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 360, height: 240)
        let shown = query.count > 48 ? query.prefix(47) + "\u{2026}" : Substring(query)
        window.title = query.isEmpty ? "Dispersion" : "Dispersion: \(shown)"
        self.init(window: window)
    }
}

private final class DispersionViewController: NSViewController {
    private let distribution: HitDistribution
    private let context: [String]
    private let plot = DispersionView()
    private let summary = NSTextField(wrappingLabelWithString: "")

    init(distribution: HitDistribution, context: [String]) {
        self.context = context
        self.distribution = distribution
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// File > Print… (see `WindowPrinting`): the plot.
    @objc func printWindowContents(_ sender: Any?) {
        WindowPrinting.run(plot, jobTitle: view.window?.title ?? "Dispersion",
                           header: PrintHeader.attributed(context + [distribution.summary]), in: view.window)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 340))
        root.autoresizingMask = [.width, .height]
        plot.counts = distribution.counts
        plot.corpusSize = distribution.corpusSize
        summary.stringValue = distribution.summary
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 2
        for view in [summary, plot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            summary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            summary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            plot.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 4),
            plot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            plot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            plot.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}
