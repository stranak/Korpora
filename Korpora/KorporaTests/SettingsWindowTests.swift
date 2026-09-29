import Cocoa
import Testing
@testable import Korpora

/// The Settings window can be resized (it wasn't), and what benefits from
/// more room gets it.
///
/// The window has to be on screen for AppKit to lay it out at all, so each
/// test orders it behind everything else and away again.
@MainActor @Suite(.serialized) struct SettingsWindowTests {
    private func shownWindow() throws -> NSWindow {
        let window = try #require(SettingsWindowController.shared.window)
        window.orderBack(nil)
        return window
    }

    private func layOut(_ window: NSWindow) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
    }

    /// Each pane opens at the size it was designed for, and that is the
    /// smallest the user can drag it to.
    @Test func isResizableAndEachPaneOpensAtItsDesignedSize() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        #expect(window.styleMask.contains(.resizable))
        let designed: [SettingsWindowController.Pane: NSSize] = [
            .corpora: NSSize(width: 540, height: 440),
            .appearance: NSSize(width: 420, height: 400),
            .concordance: NSSize(width: 460, height: 260),
        ]
        for pane in SettingsWindowController.Pane.allCases {
            SettingsWindowController.shared.showPane(pane)
            layOut(window)
            let size = try #require(designed[pane])
            #expect(window.contentMinSize == size, "\(pane) minimum")
            #expect(window.contentView?.frame.size == size, "\(pane) opening size")
        }
    }

    /// Regression: AppKit turns a non-zero `preferredContentSize` into
    /// priority-501 width/height constraints on the pane's view, which beat
    /// the window's own size constraint (500) and pinned the pane, so the
    /// window snapped back after any resize.
    @Test func thePaneFollowsTheWindow() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        for pane in SettingsWindowController.Pane.allCases {
            SettingsWindowController.shared.showPane(pane)
            layOut(window)
            window.setContentSize(NSSize(width: 800, height: 700))
            layOut(window)
            #expect(window.contentView?.frame.size == NSSize(width: 800, height: 700), "\(pane)")
        }
    }

    /// The corpus list is the point of that pane: it gets the extra room.
    @Test func theCorpusListGrowsWithTheWindow() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        SettingsWindowController.shared.showPane(.corpora)
        layOut(window)
        let controller = try #require(window.contentViewController as? CorporaSettingsViewController)
        let list = try #require(controller.tableView.enclosingScrollView)
        let before = list.frame

        window.setContentSize(NSSize(width: 760, height: 740))
        layOut(window)
        #expect(list.frame.height >= before.height + 250, "list went from \(before.height) to \(list.frame.height)")
        #expect(list.frame.width >= before.width + 180, "list went from \(before.width) to \(list.frame.width)")
    }

    @Test func theAppearanceListGrowsWithTheWindow() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        SettingsWindowController.shared.showPane(.appearance)
        layOut(window)
        let controller = try #require(window.contentViewController)
        let list = try #require(scrollViews(in: controller.view).last)
        let before = list.frame.height

        window.setContentSize(NSSize(width: 600, height: 620))
        layOut(window)
        #expect(list.frame.height >= before + 150, "list went from \(before) to \(list.frame.height)")
    }

    /// "Keep in Memory" was cut to "Keep in Me…". The table used "last column
    /// only" autoresizing, so at the opening size the columns plus spacing
    /// didn't fit and the last one shrank to 75 points (and, widened, took
    /// all the extra width). Now every heading fits its column at every
    /// window size, and extra width goes to the Name column alone.
    @Test func everyCorpusTableHeadingFitsItsColumn() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        SettingsWindowController.shared.showPane(.corpora)
        layOut(window)
        let controller = try #require(window.contentViewController as? CorporaSettingsViewController)
        let table = controller.tableView

        /// The heading text plus room for the header cell's own padding and
        /// the ellipsis it would otherwise fall back to.
        func check(_ label: String) {
            for column in table.tableColumns {
                let needed = column.headerCell.attributedStringValue.size().width + 30
                #expect(column.width >= needed, "\(label): \u{201C}\(column.title)\u{201D} needs \(needed), has \(column.width)")
            }
        }
        func widths() -> [CGFloat] { table.tableColumns.map(\.width) }

        check("opening size")
        let opening = widths()
        window.setContentSize(NSSize(width: 800, height: 500))
        layOut(window)
        check("wider")
        let wider = widths()
        #expect(wider[0] > opening[0] + 200, "Name takes the extra width: \(opening[0]) -> \(wider[0])")
        #expect(Array(wider.dropFirst()) == Array(opening.dropFirst()), "the other columns keep their widths")

        window.setContentSize(controller.view.frame.size)
        window.setContentSize(NSSize(width: 540, height: 440))
        layOut(window)
        check("back at the minimum")
        #expect(widths() == opening, "same layout at the same size")
    }

    /// The panes that are just a form (Concordance) or a form plus a list
    /// (Appearance) keep their content in a centered column of the designed
    /// width instead of leaving it in a corner of a bigger window.
    @Test func formPanesStayCenteredWhenTheWindowIsWider() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        for (pane, width) in [(SettingsWindowController.Pane.concordance, CGFloat(460)),
                              (.appearance, CGFloat(420))] {
            SettingsWindowController.shared.showPane(pane)
            layOut(window)
            window.setContentSize(NSSize(width: 900, height: 700))
            layOut(window)
            let controller = try #require(window.contentViewController)
            let column = try #require(controller.view.subviews.first, "\(pane)")
            #expect(column.frame.width == width, "\(pane) column width")
            #expect(abs(column.frame.midX - controller.view.bounds.midX) < 1, "\(pane) is centered: \(column.frame)")
            #expect(column.frame.minY == 0 && column.frame.height == controller.view.bounds.height, "\(pane) full height")
        }
    }
}
