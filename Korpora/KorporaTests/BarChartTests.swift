import Cocoa
import ManateeKit
import PDFKit
import Testing
@testable import Korpora

/// The Collocations/Frequency charts (docs/project-plan.md, 6.10).
@MainActor @Suite struct BarChartTests {
    private func chart(_ bars: [(String, Double)], width: CGFloat = 480) -> BarChartView {
        let view = BarChartView(frame: NSRect(x: 0, y: 0, width: width, height: BarChartView.height(forBars: bars.count)))
        view.bars = bars.map { .init(label: $0.0, value: $0.1) }
        view.valueTitle = "Frequency"
        return view
    }

    // MARK: Ticks and geometry

    @Test func niceTicks() {
        #expect(BarChartView.niceTicks(maximum: 1000, count: 4) == [0, 250, 500, 750, 1000])
        #expect(BarChartView.niceTicks(maximum: 7, count: 4) == [0, 2, 4, 6, 8])
        #expect(BarChartView.niceTicks(maximum: 0.83, count: 4) == [0, 0.25, 0.5, 0.75, 1.0])
        #expect(BarChartView.niceTicks(maximum: 0, count: 4) == [0])
        // Always reaches the maximum.
        for maximum in [1.0, 3.0, 99.0, 12_345.0, 0.0071, 5.5e7] {
            let ticks = BarChartView.niceTicks(maximum: maximum, count: 4)
            #expect(ticks.first == 0 && (ticks.last ?? 0) >= maximum, "\(maximum): \(ticks)")
        }
    }

    @Test func heightGrowsWithTheBars() {
        #expect(BarChartView.height(forBars: 10) > BarChartView.height(forBars: 5))
        let view = chart([("a", 1), ("b", 2), ("c", 3)])
        #expect(view.intrinsicContentSize.height == BarChartView.height(forBars: 3))
    }

    @Test func barsAreProportionalAndInOrder() {
        let view = chart([("the", 1000), ("of", 500), ("and", 250)])
        let info = view.layoutInfo(width: 480)
        let rects = view.bars.enumerated().map { info.rect(forRow: $0.offset, value: $0.element.value) }
        #expect(abs(rects[0].width - info.plot.width) < 1, "the maximum fills the axis: \(info.axisMaximum)")
        #expect(abs(rects[1].width * 2 - rects[0].width) < 1)
        #expect(abs(rects[2].width * 4 - rects[0].width) < 1)
        // First on top (the view is flipped), each in its own row.
        #expect(rects[0].minY < rects[1].minY && rects[1].minY < rects[2].minY)
        #expect(rects[1].minY - rects[0].minY == BarChartView.rowHeight)
    }

    @Test func aTinyValueStillShowsAndZeroDoesNot() {
        let view = chart([("big", 100_000), ("tiny", 1), ("none", 0)])
        let info = view.layoutInfo(width: 480)
        #expect(info.rect(forRow: 1, value: 1).width >= 1)
        #expect(info.rect(forRow: 2, value: 0).width == 0)
    }

    @Test func labelsGetRoomButNeverMoreThan40Percent() {
        let short = chart([("a", 1)]).layoutInfo(width: 480)
        let long = chart([(String(repeating: "internationalization", count: 5), 1)]).layoutInfo(width: 480)
        #expect(short.labelWidth < long.labelWidth)
        #expect(long.labelWidth <= 480 * 0.4 + 0.5)
        #expect(long.plot.width >= 40)
        // Even in a narrow window the plot doesn't collapse.
        #expect(chart([("x", 1)], width: 120).layoutInfo(width: 120).plot.width >= 40)
    }

    // MARK: Drawing

    /// Count of pixels differing noticeably from `background`, in `region`.
    private func inkPixels(_ rep: NSBitmapImageRep, background: NSColor, in region: NSRect) -> Int {
        var count = 0
        let bg = background.usingColorSpace(.sRGB) ?? background
        for x in Int(region.minX)..<min(Int(region.maxX), rep.pixelsWide) {
            for y in Int(region.minY)..<min(Int(region.maxY), rep.pixelsHigh) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let difference = abs(color.redComponent - bg.redComponent) + abs(color.greenComponent - bg.greenComponent)
                    + abs(color.blueComponent - bg.blueComponent)
                if difference > 0.6 { count += 1 }
            }
        }
        return count
    }

    private func render(_ view: BarChartView, dark: Bool) throws -> (NSBitmapImageRep, NSColor) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        let background = dark ? NSColor(white: 0.15, alpha: 1) : NSColor.white
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        background.setFill()
        view.bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        return (rep, background)
    }

    /// Text and bars are actually drawn, in both appearances: ink in the label
    /// column (the words) and in the plot (the bars).
    @Test func labelsAndBarsAreDrawnInLightAndDark() throws {
        let view = chart([("the", 1000), ("of", 800), ("and", 600)])
        let info = view.layoutInfo(width: 480)
        for dark in [false, true] {
            let (rep, background) = try render(view, dark: dark)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            let labelColumn = NSRect(x: 0, y: 0, width: (BarChartView.sideInset + info.labelWidth) * scale,
                                     height: CGFloat(rep.pixelsHigh))
            let plot = NSRect(x: info.plot.minX * scale, y: info.plot.minY * scale,
                              width: info.plot.width * scale, height: info.plot.height * scale)
            #expect(inkPixels(rep, background: background, in: labelColumn) > 50, "labels, dark: \(dark)")
            #expect(inkPixels(rep, background: background, in: plot) > 500, "bars, dark: \(dark)")
        }
    }

    /// Printing and PDF export go on white paper whatever the screen looks
    /// like. With the view in dark mode its text used to come out white on
    /// white (measured: 0 dark pixels where the words are, 483 with the fix).
    /// Rasterized with PDFKit, which renders a proper white page.
    @Test func aPDFOfADarkModeChartHasVisibleText() throws {
        func darkPixelsInLabelColumn(darkView: Bool) throws -> Int {
            let view = chart([("the", 1000), ("of", 800), ("and", 600)])
            if darkView { view.appearance = NSAppearance(named: .darkAqua) }
            let document = try #require(PDFDocument(data: view.dataWithPDF(inside: view.bounds)))
            let page = try #require(document.page(at: 0))
            let tiff = try #require(page.thumbnail(of: CGSize(width: 960, height: 520), for: .mediaBox).tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            var dark = 0
            for x in 0..<80 {
                for y in 0..<rep.pixelsHigh {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent < 0.6 { dark += 1 }
                }
            }
            return dark
        }
        let light = try darkPixelsInLabelColumn(darkView: false)
        let dark = try darkPixelsInLabelColumn(darkView: true)
        #expect(light > 100, "the words are on the printed page: \(light)")
        #expect(dark == light, "a dark-mode view prints the same words, dark on white: \(dark) vs \(light)")
    }

    @Test func emptyChartDrawsAMessageNotACrash() throws {
        let view = chart([])
        let (rep, background) = try render(view, dark: false)
        #expect(inkPixels(rep, background: background, in: NSRect(x: 0, y: 0, width: 400, height: 60)) > 20)
    }

    // MARK: Accessibility

    @Test func everyBarIsAnAccessibleElement() throws {
        let view = chart([("the", 1000), ("of", 1234)])
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children.map { $0.accessibilityLabel() } == ["the", "of"])
        #expect(children[1].accessibilityValue() as? String == "1,234 Frequency")
    }
}

/// The toggle around a results table.
@MainActor @Suite struct TableChartContainerTests {
    private func container(measures: [TableChartContainerView.Measure]) -> TableChartContainerView {
        let table = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let container = TableChartContainerView(table: table)
        container.setMeasures(measures)
        return container
    }

    private func measure(_ title: String, _ pairs: [(String, Double)]) -> TableChartContainerView.Measure {
        .init(title: title) { pairs.map { .init(label: $0.0, value: $0.1) } }
    }

    @Test func startsOnTheTableAndSwitches() {
        let c = container(measures: [measure("Frequency", [("a", 1)])])
        #expect(c.mode == .table)
        #expect(!c.table.isHidden && c.chartScrollView.isHidden && c.noteLabel.isHidden)
        c.modeControl.selectedSegment = 1
        _ = c.modeControl.sendAction(c.modeControl.action, to: c.modeControl.target)
        #expect(c.mode == .chart)
        #expect(c.table.isHidden && !c.chartScrollView.isHidden && !c.noteLabel.isHidden)
        c.setMode(.table)
        #expect(!c.table.isHidden && c.chartScrollView.isHidden)
        #expect(c.modeControl.selectedSegment == 0)
    }

    /// The measure pop-up only matters with a choice, and only in chart mode.
    @Test func theMeasurePopUpAppearsOnlyWhenThereIsAChoice() {
        let one = container(measures: [measure("Frequency", [("a", 1)])])
        one.setMode(.chart)
        #expect(one.measurePopUp.isHidden)

        let several = container(measures: [measure("Score", [("a", 1)]), measure("Frequency", [("a", 2)])])
        #expect(several.measurePopUp.isHidden, "not in table mode")
        several.setMode(.chart)
        #expect(!several.measurePopUp.isHidden)
        #expect(several.measurePopUp.itemTitles == ["Score", "Frequency"])
    }

    /// Ranked by the measure, best first, whatever order the data came in.
    @Test func theChartRanksByTheMeasure() {
        let c = container(measures: [measure("Frequency", [("b", 5), ("a", 5), ("c", 9), ("d", 1)])])
        c.setMode(.chart)
        #expect(c.chart.bars.map(\.label) == ["c", "a", "b", "d"], "ties by label")
        #expect(c.chart.valueTitle == "Frequency")
        #expect(c.noteLabel.stringValue == "4 results")
    }

    @Test func aLongListIsCutToTheTopAndSaysSo() {
        let many = (0..<75).map { ("word\($0)", Double(75 - $0)) }
        let c = container(measures: [measure("Frequency", many)])
        c.setMode(.chart)
        #expect(c.chart.bars.count == TableChartContainerView.maxBars)
        #expect(c.chart.bars.first?.label == "word0" && c.chart.bars.last?.label == "word39")
        #expect(c.noteLabel.stringValue == "Top 40 of 75 by frequency")
        #expect(c.chart.frame.height == BarChartView.height(forBars: 40))
    }

    @Test func choosingAnotherMeasureRedrawsTheChart() {
        let c = container(measures: [measure("Score", [("a", 9), ("b", 1)]), measure("Frequency", [("a", 1), ("b", 9)])])
        c.setMode(.chart)
        #expect(c.chart.bars.map(\.label) == ["a", "b"])
        c.measurePopUp.selectItem(at: 1)
        _ = c.measurePopUp.sendAction(c.measurePopUp.action, to: c.measurePopUp.target)
        #expect(c.chart.bars.map(\.label) == ["b", "a"])
        #expect(c.chart.valueTitle == "Frequency")
        #expect(c.noteLabel.stringValue == "2 results")
    }
}

/// The two real windows.
@MainActor @Suite struct ResultsWindowChartTests {
    private func container(of window: NSWindow?) throws -> TableChartContainerView {
        try #require(window?.contentViewController?.view as? TableChartContainerView)
    }

    @Test func theFrequencyWindowChartsFrequenciesWithReadableKeys() throws {
        let items = [
            FrequencyItem(word: "the", freq: 50),
            FrequencyItem(word: "cat\tNN", freq: 7),  // a two-level key
            FrequencyItem(word: "of", freq: 20),
        ]
        let controller = FrequencyWindowController(criterion: .init(attribute: "word"), items: items)
        let c = try container(of: controller.window)
        c.setMode(.chart)
        #expect(c.chart.bars.map(\.label) == ["the", "of", "cat \u{00B7} NN"])
        #expect(c.chart.bars.map(\.value) == [50, 20, 7])
        #expect(c.measurePopUp.isHidden, "one measure, no pop-up")
    }

    @Test func theCollocationWindowOffersScoreCooccurrencesAndFrequency() throws {
        let items = [
            CollocationItem(word: "brown", freq: 40, cnt: 3, score: 8.5),
            CollocationItem(word: "quick", freq: 10, cnt: 9, score: 7.25),
        ]
        let controller = CollocationWindowController(spec: CollocationSpec(attribute: "word"), items: items)
        let c = try container(of: controller.window)
        c.setMode(.chart)
        #expect(c.measurePopUp.itemTitles == ["Score", "Co-occurrences", "Frequency"])
        #expect(c.chart.bars == [.init(label: "brown", value: 8.5), .init(label: "quick", value: 7.25)])
        c.measurePopUp.selectItem(withTitle: "Co-occurrences")
        _ = c.measurePopUp.sendAction(c.measurePopUp.action, to: c.measurePopUp.target)
        #expect(c.chart.bars == [.init(label: "quick", value: 9), .init(label: "brown", value: 3)])
        // The table is still there, and the window still resizes.
        c.setMode(.table)
        #expect(!c.table.isHidden)
        #expect(controller.window?.styleMask.contains(.resizable) == true)
    }
}
