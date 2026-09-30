import Cocoa

/// A horizontal bar chart of labelled values, for the Collocations and
/// Frequency windows (docs/project-plan.md, 6.10): labels on the left, one
/// bar per value with its number at the end, a value axis with gridlines
/// underneath.
///
/// Drawn by hand rather than with Swift Charts. The spike for 6.10 found that
/// a hosted chart prints as an empty page, that its bars and labels came out
/// differently from what the modifiers asked for in every renderer I could
/// check, and that its look is the OS's to change (the app runs on macOS 15
/// to 27). This draws the same on screen, in print and in a PDF, follows
/// light/dark mode through dynamic colors, and is tested by rendering it.
final class BarChartView: NSView {
    struct Bar: Equatable {
        let label: String
        let value: Double
    }

    var bars: [Bar] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }
    /// What the values are ("Frequency"): the axis title.
    var valueTitle = "" { didSet { needsDisplay = true } }
    var valueFormat: (Double) -> String = BarChartView.defaultFormat

    static let rowHeight: CGFloat = 24
    static let barHeight: CGFloat = 15
    static let topInset: CGFloat = 12
    static let axisHeight: CGFloat = 46
    static let sideInset: CGFloat = 16
    /// Room after the longest bar for its number.
    static let valueRoom: CGFloat = 64

    static let defaultFormat: (Double) -> String = { value in
        if value == value.rounded() { return Int(value).formatted(.number) }
        return value.formatted(.number.precision(.fractionLength(0...3)))
    }

    override var isFlipped: Bool { true }

    /// Tall enough for every bar (a scroll view takes it from here); the
    /// width is the container's business.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height(forBars: bars.count))
    }

    static func height(forBars count: Int) -> CGFloat {
        topInset + CGFloat(max(count, 1)) * rowHeight + axisHeight
    }

    // MARK: Geometry

    /// Where everything goes for the current bars and width; also what the
    /// tests and the accessibility elements read.
    struct Layout {
        var labelWidth: CGFloat
        var plot: NSRect
        var axisMaximum: Double
        var ticks: [Double]

        func rect(forRow row: Int, value: Double) -> NSRect {
            let y = BarChartView.topInset + CGFloat(row) * BarChartView.rowHeight
                + (BarChartView.rowHeight - BarChartView.barHeight) / 2
            let width = axisMaximum > 0 ? plot.width * CGFloat(value / axisMaximum) : 0
            return NSRect(x: plot.minX, y: y, width: max(width, value > 0 ? 1 : 0), height: BarChartView.barHeight)
        }
    }

    /// Faint enough to sit behind the numbers, on screen (either appearance)
    /// and on paper.
    private static let gridColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.13)
    }

    private static let labelFont = NSFont.systemFont(ofSize: 11)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    func layoutInfo(width: CGFloat) -> Layout {
        let longest = bars.map { ($0.label as NSString).size(withAttributes: [.font: Self.labelFont]).width }.max() ?? 0
        // Labels get what they need, but never more than 40% of the width.
        let labelWidth = min(ceil(longest) + 8, max(60, width * 0.4))
        let plotWidth = max(40, width - Self.sideInset * 2 - labelWidth - Self.valueRoom)
        let plot = NSRect(x: Self.sideInset + labelWidth, y: Self.topInset,
                          width: plotWidth, height: CGFloat(max(bars.count, 1)) * Self.rowHeight)
        let maximum = bars.map(\.value).max() ?? 0
        let ticks = Self.niceTicks(maximum: maximum, count: 4)
        return Layout(labelWidth: labelWidth, plot: plot, axisMaximum: ticks.last ?? maximum, ticks: ticks)
    }

    /// Round tick values from 0 up to a "nice" maximum at or above `maximum`
    /// (1, 2, 2.5, 5 times a power of ten), about `count` intervals.
    static func niceTicks(maximum: Double, count: Int) -> [Double] {
        guard maximum > 0, count > 0 else { return [0] }
        let rough = maximum / Double(count)
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0].map { $0 * magnitude }.first { $0 >= rough } ?? 10 * magnitude
        var ticks: [Double] = []
        var value = 0.0
        while value < maximum + step * 1e-9 {
            ticks.append(value)
            value += step
        }
        if ticks.last.map({ $0 < maximum }) ?? true { ticks.append(value) }
        return ticks
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Print and PDF go on white paper whatever the screen looks like: with
        // the view in dark mode its text would come out white on white.
        if NSGraphicsContext.current?.isDrawingToScreen == false {
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { drawChart() }
        } else {
            drawChart()
        }
    }

    private func drawChart() {
        let info = layoutInfo(width: bounds.width)
        guard !bars.isEmpty else {
            let text = "Nothing to show" as NSString
            text.draw(at: NSPoint(x: Self.sideInset, y: Self.topInset),
                      withAttributes: [.font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let plotBottom = info.plot.maxY

        // Gridlines and the value axis.
        Self.gridColor.setStroke()
        let axisText: [NSAttributedString.Key: Any] = [.font: Self.numberFont, .foregroundColor: NSColor.secondaryLabelColor]
        for tick in info.ticks {
            let x = info.plot.minX + info.plot.width * CGFloat(info.axisMaximum > 0 ? tick / info.axisMaximum : 0)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x.rounded() + 0.5, y: info.plot.minY))
            line.line(to: NSPoint(x: x.rounded() + 0.5, y: plotBottom + 3))
            line.lineWidth = 1
            line.stroke()
            let label = valueFormat(tick) as NSString
            let size = label.size(withAttributes: axisText)
            label.draw(at: NSPoint(x: x - size.width / 2, y: plotBottom + 5), withAttributes: axisText)
        }
        if !valueTitle.isEmpty {
            let title = valueTitle as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
            let size = title.size(withAttributes: attributes)
            title.draw(at: NSPoint(x: info.plot.midX - size.width / 2, y: plotBottom + 22), withAttributes: attributes)
        }

        // Bars, labels, numbers.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: Self.numberFont, .foregroundColor: NSColor.secondaryLabelColor]
        for (row, bar) in bars.enumerated() {
            let rect = info.rect(forRow: row, value: bar.value)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

            let labelSize = (bar.label as NSString).size(withAttributes: labelAttributes)
            let labelRect = NSRect(x: Self.sideInset, y: rect.midY - labelSize.height / 2,
                                   width: info.labelWidth - 8, height: labelSize.height)
            (bar.label as NSString).draw(in: labelRect, withAttributes: labelAttributes)

            let number = valueFormat(bar.value) as NSString
            let numberSize = number.size(withAttributes: numberAttributes)
            number.draw(at: NSPoint(x: rect.maxX + 5, y: rect.midY - numberSize.height / 2), withAttributes: numberAttributes)
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { false }

    /// One element per bar, "the, 1,000 Frequency", so VoiceOver can walk them.
    override func accessibilityChildren() -> [Any]? {
        let info = layoutInfo(width: bounds.width)
        return bars.enumerated().map { row, bar in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(bar.label)
            element.setAccessibilityValue("\(valueFormat(bar.value)) \(valueTitle)")
            element.setAccessibilityParent(self)
            let rowRect = NSRect(x: 0, y: Self.topInset + CGFloat(row) * Self.rowHeight,
                                 width: bounds.width, height: Self.rowHeight)
            element.setAccessibilityFrameInParentSpace(rowRect)
            _ = info
            return element
        }
    }
}
