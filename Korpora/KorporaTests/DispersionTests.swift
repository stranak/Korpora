import Cocoa
import PDFKit
import Testing
@testable import Korpora

/// The dispersion plot (docs/project-plan.md, 6.10).
@MainActor @Suite struct DispersionTests {
    private func plot(_ counts: [Int], size: NSSize = NSSize(width: 640, height: 300)) -> DispersionView {
        let view = DispersionView(frame: NSRect(origin: .zero, size: size))
        view.counts = counts
        view.corpusSize = 1_000_000
        return view
    }

    // MARK: Summary

    @Test func distributionSummary() {
        let d = HitDistribution(counts: [3, 0, 1, 2], corpusSize: 2_000_000)
        #expect(d.hits == 6)
        #expect(d.tokensPerBin == 500_000)
        #expect(d.summary.contains("6 hits"))
        #expect(d.summary.contains("2,000,000-token"))
        #expect(d.summary.contains("4 parts"))
        #expect(HitDistribution(counts: [1], corpusSize: 10).summary.contains("1 hit "))
    }

    @Test func emptyDistributionDoesNotDivideByZero() {
        let d = HitDistribution(counts: [], corpusSize: 0)
        #expect(d.hits == 0 && d.tokensPerBin == 1)
        #expect(!d.summary.isEmpty)
    }

    @Test func tokenLabelsAreShort() {
        #expect(DispersionView.tokens(0) == "0")
        #expect(DispersionView.tokens(1234) == "1,234")
        #expect(DispersionView.tokens(12_000) == "12K")
        #expect(DispersionView.tokens(4_500_000) == "4.5M")
        #expect(DispersionView.tokens(3_410_000_000) == "3.41G")
    }

    // MARK: Geometry

    @Test func columnsAreProportionalAndSideBySide() {
        let view = plot([10, 5, 0, 20])
        let info = view.layoutInfo(size: view.bounds.size)
        #expect(info.yMaximum >= 20)
        let c = view.counts.enumerated().map { info.column(bin: $0.offset, bins: 4, count: $0.element) }
        #expect(abs(c[0].height * 2 - c[3].height * (10.0 / 20.0) * 2) < 0.01)
        #expect(abs(c[1].height * 2 - c[0].height) < 0.5)
        #expect(c[2].height == 0)
        #expect(c[0].minX < c[1].minX && c[1].minX < c[3].minX)
        // Columns stand on the axis and stay inside the plot.
        for column in c where column.height > 0 {
            #expect(abs(column.maxY - info.plot.maxY) < 0.01)
            #expect(column.minX >= info.plot.minX - 0.01 && column.maxX <= info.plot.maxX + 0.01)
        }
    }

    @Test func aSingleHitStillShows() {
        let view = plot([1, 0, 0, 100_000])
        let info = view.layoutInfo(size: view.bounds.size)
        #expect(info.column(bin: 0, bins: 4, count: 1).height >= 1)
    }

    @Test func plotSurvivesTinyWindows() {
        let info = plot([1, 2], size: NSSize(width: 10, height: 10)).layoutInfo(size: NSSize(width: 10, height: 10))
        #expect(info.plot.width >= 40 && info.plot.height >= 40)
    }

    // MARK: Drawing

    private func render(_ view: NSView, dark: Bool) throws -> (NSBitmapImageRep, NSColor) {
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

    private func ink(_ rep: NSBitmapImageRep, background: NSColor, in region: NSRect) -> Int {
        var count = 0
        let bg = background.usingColorSpace(.sRGB) ?? background
        for x in Int(region.minX)..<min(Int(region.maxX), rep.pixelsWide) {
            for y in Int(region.minY)..<min(Int(region.maxY), rep.pixelsHigh) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let d = abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent)
                if d > 0.6 { count += 1 }
            }
        }
        return count
    }

    @Test func columnsAndAxisTextAreDrawnInLightAndDark() throws {
        let view = plot([2, 8, 4, 10, 1])
        let info = view.layoutInfo(size: view.bounds.size)
        for dark in [false, true] {
            let (rep, background) = try render(view, dark: dark)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            func px(_ r: NSRect) -> NSRect { NSRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale) }
            #expect(ink(rep, background: background, in: px(info.plot)) > 2000, "columns, dark: \(dark)")
            let axisText = NSRect(x: 0, y: info.plot.maxY + 5, width: view.bounds.width, height: 40)
            #expect(ink(rep, background: background, in: px(axisText)) > 100, "axis text, dark: \(dark)")
        }
    }

    @Test func gridlinesAreTheConfiguredColor() throws {
        let view = plot([2, 8, 4, 10, 1])
        let info = view.layoutInfo(size: view.bounds.size)
        let (rep, _) = try render(view, dark: false)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        // A column-free spot at the far right of the plot, on each gridline.
        let x = Int((info.plot.maxX - 3) * scale)
        var values: [CGFloat] = []
        for tick in info.yTicks.dropFirst() {
            let y = info.plot.maxY - info.plot.height * CGFloat(tick / info.yMaximum)
            let c = try #require(rep.colorAt(x: x, y: Int(y.rounded() * scale))?.usingColorSpace(.sRGB))
            values.append(c.redComponent)
        }
        #expect(values.count >= 2)
        #expect(values.allSatisfy { abs($0 - 0.88) < 0.03 }, "\(values)")
    }

    @Test func emptyPlotSaysSo() throws {
        let view = plot([0, 0, 0])
        let (rep, background) = try render(view, dark: false)
        #expect(ink(rep, background: background, in: NSRect(x: 0, y: 0, width: 300, height: 60)) > 20)
    }

    @Test func printingADarkModePlotStaysReadable() throws {
        let view = plot([2, 8, 4, 10, 1])
        view.appearance = NSAppearance(named: .darkAqua)
        let data = view.dataWithPDF(inside: view.bounds)
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        let image = page.thumbnail(of: NSSize(width: 1280, height: 600), for: .mediaBox)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        #expect(ink(rep, background: .white, in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)) > 400)
    }

    // MARK: Accessibility

    @Test func accessibilityDescribesThePeak() {
        let label = plot([1, 9, 3]).accessibilityLabel() ?? ""
        #expect(label.localizedCaseInsensitiveContains("dispersion") || label.contains("hit"), "\(label)")
        #expect(!(plot([]).accessibilityLabel() ?? "").isEmpty)
    }

    // MARK: Window

    @Test func windowShowsTheSummaryAndThePlot() throws {
        let d = HitDistribution(counts: [1, 2, 3], corpusSize: 900)
        let controller = DispersionWindowController(query: "[lemma=\"cat\"]", distribution: d)
        let window = try #require(controller.window)
        #expect(window.title == "Dispersion: [lemma=\"cat\"]")
        #expect(window.styleMask.contains(.resizable))
        let root = try #require(window.contentView)
        func find<T: NSView>(_: T.Type, in view: NSView) -> T? {
            if let v = view as? T { return v }
            return view.subviews.lazy.compactMap { find(T.self, in: $0) }.first
        }
        #expect(find(DispersionView.self, in: root)?.counts == [1, 2, 3])
        #expect(find(NSTextField.self, in: root)?.stringValue == d.summary)
        let long = DispersionWindowController(query: String(repeating: "x", count: 200), distribution: d)
        #expect((long.window?.title.count ?? 999) < 70)
    }

    @Test func toolbarOffersTheDispersionButton() throws {
        let identifiers = ConcordanceWindowController().toolbarDefaultItemIdentifiers(NSToolbar())
        #expect(identifiers.contains(ConcordanceWindowController.ItemID.dispersion))
    }
}
