import Cocoa
import ManateeKit
import Testing
@testable import Korpora

/// File > Print… works in every results window, not only the concordance's:
/// the menu item is enabled by whichever window is key implementing its action.
@MainActor @Suite struct WindowPrintingTests {
    private let action = #selector(ConcordanceViewController.printWindowContents(_:))

    private func printMenuItem() -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == "Print…" { return item }
                if let sub = item.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    @Test func theMenuItemUsesTheSharedAction() throws {
        let item = try #require(printMenuItem())
        #expect(item.action == action)
        #expect(item.target == nil, "resolved through the responder chain")
    }

    @Test func everyAuxiliaryWindowCanPrint() throws {
        let info = ConcordanceDocument.ExtendedContextInfo(corpusName: "c", documentLabel: nil, sentenceLabel: nil)
        let windows: [(String, NSWindowController)] = [
            ("Frequencies", FrequencyWindowController(criterion: .init(attribute: "word"), items: [FrequencyItem(word: "a", freq: 1)])),
            ("Collocations", CollocationWindowController(spec: CollocationSpec(attribute: "word"),
                                                         items: [CollocationItem(word: "a", freq: 1, cnt: 1, score: 1)])),
            ("Dispersion", DispersionWindowController(query: "x", distribution: HitDistribution(counts: [1], corpusSize: 10))),
            ("Extended Context", ExtendedContextWindowController(info: info, before: "a", match: "b", after: "c")),
        ]
        for (name, controller) in windows {
            let viewController = try #require(controller.window?.contentViewController, "\(name)")
            #expect(viewController.responds(to: action), "\(name) can't print")
        }
    }

    @Test func printsTheChartWhenShowingAndTheTableOtherwise() {
        let scroll = NSScrollView()
        let table = NSTableView()
        scroll.documentView = table
        let container = TableChartContainerView(table: scroll)
        #expect(container.printableView === table)
        container.setMode(.chart)
        #expect(container.printableView === container.chart)
    }
}
