import Cocoa

/// The body of a results window (Collocations, Frequencies): its table, or a
/// bar chart of the same results, chosen with a "Table | Chart" switch
/// (docs/project-plan.md, 6.10). With more than one measure to chart there's
/// a pop-up to choose which.
///
/// The chart always ranks by the chosen measure, best first and at most
/// `maxBars`, whatever the table happens to be sorted by; a note says how
/// many of the results it shows.
final class TableChartContainerView: NSView {
    struct Measure {
        let title: String
        /// All bars for this measure, in any order; the container ranks and cuts.
        let bars: () -> [BarChartView.Bar]
    }

    enum Mode: Int { case table, chart }

    static let maxBars = 40

    let table: NSScrollView
    let chartScrollView = NSScrollView()
    let chart = BarChartView()
    let modeControl = NSSegmentedControl(
        labels: ["Table", "Chart"], trackingMode: .selectOne, target: nil, action: nil)
    let measurePopUp = NSPopUpButton()
    let noteLabel = NSTextField(labelWithString: "")

    private(set) var mode: Mode = .table
    private var measures: [Measure] = []

    init(table: NSScrollView) {
        self.table = table
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 360))

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = Mode.table.rawValue
        modeControl.segmentStyle = .rounded
        measurePopUp.target = self
        measurePopUp.action = #selector(measureChanged)
        measurePopUp.controlSize = .small
        measurePopUp.isHidden = true
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.isHidden = true

        chart.autoresizingMask = [.width]
        chartScrollView.documentView = chart
        chartScrollView.hasVerticalScroller = true
        chartScrollView.drawsBackground = false
        chartScrollView.isHidden = true

        for view in [modeControl, measurePopUp, noteLabel, table, chartScrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            modeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            measurePopUp.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            measurePopUp.leadingAnchor.constraint(equalTo: modeControl.trailingAnchor, constant: 10),
            noteLabel.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            noteLabel.leadingAnchor.constraint(greaterThanOrEqualTo: measurePopUp.trailingAnchor, constant: 10),
            noteLabel.leadingAnchor.constraint(greaterThanOrEqualTo: modeControl.trailingAnchor, constant: 10),

            table.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),

            chartScrollView.topAnchor.constraint(equalTo: table.topAnchor),
            chartScrollView.leadingAnchor.constraint(equalTo: table.leadingAnchor),
            chartScrollView.trailingAnchor.constraint(equalTo: table.trailingAnchor),
            chartScrollView.bottomAnchor.constraint(equalTo: table.bottomAnchor),
        ])
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// What can be charted. The first is shown initially; with several, the
    /// pop-up appears in chart mode.
    func setMeasures(_ measures: [Measure], valueTitleFormat: ((Double) -> String)? = nil) {
        self.measures = measures
        measurePopUp.removeAllItems()
        measurePopUp.addItems(withTitles: measures.map(\.title))
        if let valueTitleFormat { chart.valueFormat = valueTitleFormat }
        refreshChart()
    }

    func setMode(_ newMode: Mode) {
        mode = newMode
        modeControl.selectedSegment = newMode.rawValue
        table.isHidden = newMode == .chart
        chartScrollView.isHidden = newMode == .table
        measurePopUp.isHidden = newMode == .table || measures.count < 2
        noteLabel.isHidden = newMode == .table
        if newMode == .chart { refreshChart() }
    }

    @objc private func modeChanged() {
        setMode(Mode(rawValue: modeControl.selectedSegment) ?? .table)
    }

    @objc private func measureChanged() {
        refreshChart()
    }

    var selectedMeasure: Measure? {
        measures.indices.contains(measurePopUp.indexOfSelectedItem) ? measures[measurePopUp.indexOfSelectedItem] : measures.first
    }

    /// Ranks by the chosen measure and cuts to `maxBars`.
    func refreshChart() {
        guard let measure = selectedMeasure else { return }
        let all = measure.bars()
        let ranked = all.sorted { $0.value != $1.value ? $0.value > $1.value : $0.label < $1.label }
        let shown = Array(ranked.prefix(Self.maxBars))
        chart.valueTitle = measure.title
        chart.bars = shown
        let width = max(chartScrollView.contentSize.width, 200)
        chart.frame = NSRect(x: 0, y: 0, width: width, height: BarChartView.height(forBars: shown.count))
        noteLabel.stringValue = all.count > shown.count
            ? "Top \(shown.count) of \(all.count) by \(measure.title.lowercased())"
            : "\(shown.count) result\(shown.count == 1 ? "" : "s")"
    }
}
