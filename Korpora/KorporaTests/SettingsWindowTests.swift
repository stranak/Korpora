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
}
