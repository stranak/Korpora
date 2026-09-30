import Cocoa

/// Where a concordance's hits fall across the corpus (docs/project-plan.md,
/// 6.10): a column per stretch of the corpus, as tall as the number of hits
/// that start in it. A word used evenly looks flat; one tied to a part of
/// the corpus (a chapter, a period, a genre) shows as a hump.
///
/// Hand-drawn like `BarChartView`, for the same reasons.
final class DispersionView: NSView, PrintHeaderDrawing {
    var counts: [Int] = [] {
        didSet { needsDisplay = true; NSAccessibility.post(element: self, notification: .valueChanged) }
    }
    /// Tokens in the corpus the positions are numbered in; labels the x axis.
    var corpusSize = 0 { didSet { needsDisplay = true } }

    static let leftInset: CGFloat = 52
    static let rightInset: CGFloat = 20
    static let topInset: CGFloat = 14
    static let bottomInset: CGFloat = 50

    override var isFlipped: Bool { true }

    var printHeaderLines: [NSAttributedString] = []

    override func drawPageBorder(with borderSize: NSSize) {
        super.drawPageBorder(with: borderSize)
        PrintHeader.draw(printHeaderLines, borderSize: borderSize)
    }

    struct Layout {
        var plot: NSRect
        var yMaximum: Double
        var yTicks: [Double]

        /// The column for `bin` of `bins` with `count` hits.
        func column(bin: Int, bins: Int, count: Int) -> NSRect {
            let width = plot.width / CGFloat(max(bins, 1))
            let height = yMaximum > 0 ? plot.height * CGFloat(Double(count) / yMaximum) : 0
            // A gap between columns only when they're wide enough to afford it.
            let gap: CGFloat = width > 4 ? 1 : 0
            return NSRect(x: plot.minX + CGFloat(bin) * width, y: plot.maxY - height,
                          width: max(width - gap, 0.5), height: count > 0 ? max(height, 1) : 0)
        }
    }

    func layoutInfo(size: NSSize) -> Layout {
        let plot = NSRect(x: Self.leftInset, y: Self.topInset,
                          width: max(size.width - Self.leftInset - Self.rightInset, 40),
                          height: max(size.height - Self.topInset - Self.bottomInset, 40))
        let ticks = BarChartView.niceTicks(maximum: Double(counts.max() ?? 0), count: 4)
        return Layout(plot: plot, yMaximum: ticks.last ?? 0, yTicks: ticks)
    }

    private static let font = NSFont.systemFont(ofSize: 11)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        drawingForScreenOrPaper { drawPlot() }
    }

    private func drawPlot() {
        let info = layoutInfo(size: bounds.size)
        guard !counts.isEmpty, counts.contains(where: { $0 > 0 }) else {
            ("No hits to plot" as NSString).draw(
                at: NSPoint(x: Self.leftInset, y: Self.topInset),
                withAttributes: [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let numbers: [NSAttributedString.Key: Any] = [.font: Self.numberFont, .foregroundColor: NSColor.secondaryLabelColor]

        // Horizontal gridlines with the hit counts at the left. The stroke color
        // is set for every line: drawing text between them changes it.
        for tick in info.yTicks {
            ChartColors.grid.setStroke()
            let y = info.plot.maxY - info.plot.height * CGFloat(info.yMaximum > 0 ? tick / info.yMaximum : 0)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: info.plot.minX, y: y.rounded() + 0.5))
            line.line(to: NSPoint(x: info.plot.maxX, y: y.rounded() + 0.5))
            line.lineWidth = 1
            line.stroke()
            let label = BarChartView.defaultFormat(tick) as NSString
            let size = label.size(withAttributes: numbers)
            label.draw(at: NSPoint(x: info.plot.minX - size.width - 6, y: y - size.height / 2), withAttributes: numbers)
        }

        NSColor.controlAccentColor.setFill()
        for (bin, count) in counts.enumerated() where count > 0 {
            NSBezierPath(rect: info.column(bin: bin, bins: counts.count, count: count)).fill()
        }

        // The corpus axis: percentages, with the token position under each.
        ChartColors.axis.setStroke()
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: info.plot.minX, y: info.plot.maxY + 0.5))
        axis.line(to: NSPoint(x: info.plot.maxX, y: info.plot.maxY + 0.5))
        axis.lineWidth = 1
        axis.stroke()
        for quarter in 0...4 {
            ChartColors.axis.setStroke()
            let fraction = CGFloat(quarter) / 4
            let x = info.plot.minX + info.plot.width * fraction
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x, y: info.plot.maxY))
            tick.line(to: NSPoint(x: x, y: info.plot.maxY + 4))
            tick.stroke()
            for (text, dy) in [("\(quarter * 25)%", CGFloat(6)), (Self.tokens(Int(Double(corpusSize) * Double(fraction))), 19)] {
                let label = text as NSString
                let size = label.size(withAttributes: numbers)
                var origin = x - size.width / 2
                origin = min(max(origin, 2), bounds.width - size.width - 2)
                label.draw(at: NSPoint(x: origin, y: info.plot.maxY + dy), withAttributes: numbers)
            }
        }
        let title = "Position in the corpus (tokens)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]
        let titleSize = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: info.plot.midX - titleSize.width / 2, y: info.plot.maxY + 33), withAttributes: attributes)
    }

    /// 1,234 / 12.3K / 4.5M / 1.2G: short enough to sit under a tick.
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch value {
        case ..<10_000: return count.formatted(.number)
        case ..<1_000_000: return String(format: "%.0fK", value / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", value / 1_000_000)
        default: return String(format: "%.2fG", value / 1_000_000_000)
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? {
        let hits = counts.reduce(0, +)
        guard hits > 0 else { return "Dispersion plot: no hits" }
        let peak = counts.enumerated().max { $0.element < $1.element }
        let peakPercent = peak.map { $0.offset * 100 / max(counts.count, 1) } ?? 0
        return "Dispersion plot of \(hits) hits across the corpus in \(counts.count) parts; "
            + "the busiest part starts \(peakPercent) percent in, with \(peak?.element ?? 0) hits"
    }
}
