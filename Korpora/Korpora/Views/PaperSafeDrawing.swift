import Cocoa

extension NSView {
    /// Runs `drawing` with the appearance it should have: the view's own on
    /// screen, but always the light one for print and PDF, which go on white
    /// paper. Without it a view in dark mode prints its text white on white
    /// (found by looking at the PDF of a chart; see `BarChartTests`).
    func drawingForScreenOrPaper(_ drawing: () -> Void) {
        if NSGraphicsContext.current?.isDrawingToScreen == false {
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance(drawing)
        } else {
            drawing()
        }
    }
}

/// Colors shared by the hand-drawn charts. Opaque on purpose: a translucent
/// line piles up if the view is drawn more than once over the same pixels
/// (as `cacheDisplay` does), and comes out darker than asked for.
enum ChartColors {
    static let grid = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.30, alpha: 1) : NSColor(white: 0.88, alpha: 1)
    }
    static let axis = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.50, alpha: 1)
    }
}
