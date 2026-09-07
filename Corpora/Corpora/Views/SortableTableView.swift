import Cocoa

/// Notifies `onSortDescriptorsChange` whenever `sortDescriptors` changes -
/// including from AppKit's own built-in column-header-click handling.
/// `NSTableViewDiffableDataSource` (our data source) doesn't implement the
/// optional `NSTableViewDataSource.tableView(_:sortDescriptorsDidChange:)`
/// forwarding, so observing the property directly via Swift's override
/// syntax is the reliable way to hear about a header click regardless of
/// which data source class is in use.
final class SortableTableView: NSTableView {
    var onSortDescriptorsChange: (([NSSortDescriptor]) -> Void)?

    override var sortDescriptors: [NSSortDescriptor] {
        didSet { onSortDescriptorsChange?(sortDescriptors) }
    }

    /// Drawn at the top of every printed/PDF'd page (see `drawPageBorder`) -
    /// e.g. the query and its hit-count/corpus-size status line, styled to
    /// match how they look live above the table on screen (see
    /// `CQLQueryField.syntaxColoredAttributedString`) rather than plain
    /// black text. `ConcordanceViewController.printConcordance(_:)` sets
    /// this right before printing; on-screen drawing never calls
    /// `drawPageBorder`, so this has no effect outside an actual print/PDF
    /// operation.
    var printHeaderLines: [NSAttributedString] = []

    override func drawPageBorder(with borderSize: NSSize) {
        super.drawPageBorder(with: borderSize)
        var y = borderSize.height - 16
        for line in printHeaderLines {
            line.draw(at: NSPoint(x: 0, y: y))
            y -= 16
        }
    }
}
