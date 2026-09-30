import Cocoa

/// File > Print… for the auxiliary results windows (Collocations, Frequencies,
/// Dispersion, Extended Context). The menu item targets `printWindowContents(_:)`
/// through the responder chain, and is enabled only when the key window's
/// controller implements it - the concordance window and each of these do.
enum WindowPrinting {
    /// Runs the standard print panel (which also offers Save as PDF) for `view`,
    /// as a sheet on `window`.
    @MainActor
    static func run(_ view: NSView, jobTitle: String, in window: NSWindow?) {
        let operation = NSPrintOperation(view: view)
        operation.jobTitle = jobTitle
        operation.printInfo.horizontalPagination = .fit
        operation.printInfo.verticalPagination = .automatic
        operation.printInfo.isVerticallyCentered = false
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
}
