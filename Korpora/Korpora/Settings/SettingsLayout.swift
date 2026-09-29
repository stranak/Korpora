import Cocoa

/// Shared layout for the Settings panes (docs/project-plan.md, "Settings
/// window: resizable").
enum SettingsLayout {
    /// The root view for a pane laid out as a column of a fixed `width`:
    /// kept horizontally centered as the window is resized, and as tall as
    /// the window, so whatever in the column can stretch vertically (a list)
    /// does. For panes with nothing worth widening, which would otherwise
    /// sit in the top-left corner of an enlarged window.
    static func centeredRoot(around column: NSView, width: CGFloat) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: column.frame.height))
        // Follow the window; without this Auto Layout pins the view to the
        // size it was created with.
        root.autoresizingMask = [.width, .height]
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            column.widthAnchor.constraint(equalToConstant: width),
        ])
        return root
    }
}
