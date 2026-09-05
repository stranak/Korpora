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
}
