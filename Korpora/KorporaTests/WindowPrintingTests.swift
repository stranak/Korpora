import Cocoa
import PDFKit
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

/// The printed pages really carry the header, and the panel's checkbox setting
/// (`PrintHeader.isEnabled`) really removes it.
@MainActor @Suite(.serialized) struct PrintHeaderTests {
    private func printedText(_ view: NSView & PrintHeaderDrawing, header: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.horizontalPagination = .fit
        info.topMargin = PrintHeader.margin(forLines: header.count)
        view.printHeaderLines = PrintHeader.attributed(header)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        #expect(operation.run())
        let pdf = try #require(PDFDocument(url: url))
        return pdf.string ?? ""
    }

    private func chart() -> BarChartView {
        let view = BarChartView(frame: NSRect(x: 0, y: 0, width: 400, height: BarChartView.height(forBars: 2)))
        view.bars = [.init(label: "alpha", value: 2), .init(label: "beta", value: 1)]
        return view
    }

    @Test func theHeaderIsPrintedByDefaultAndOmittedWhenSwitchedOff() throws {
        let saved = PrintHeader.isEnabled
        defer { PrintHeader.isEnabled = saved }
        let lines = ["Collocations \u{2013} syn2025", "Query: [lemma=\"cat\"]", "Collocates by lemma, measure logDice"]
        PrintHeader.isEnabled = true
        let with = try printedText(chart(), header: lines)
        #expect(with.contains("syn2025") && with.contains("Query:") && with.contains("logDice"), "\(with)")
        #expect(with.contains("alpha"))
        PrintHeader.isEnabled = false
        let without = try printedText(chart(), header: lines)
        #expect(!without.contains("syn2025") && !without.contains("Query:"), "\(without)")
        #expect(without.contains("alpha"))
    }

    @Test func aTableCarriesTheHeaderToo() throws {
        let saved = PrintHeader.isEnabled
        defer { PrintHeader.isEnabled = saved }
        PrintHeader.isEnabled = true
        let table = SortableTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let column = NSTableColumn(identifier: .init("w"))
        column.title = "Word"
        table.addTableColumn(column)
        let text = try printedText(table, header: ["Frequencies \u{2013} corp", "Query: x"])
        #expect(text.contains("Frequencies") && text.contains("Query: x"), "\(text)")
    }

    @Test func aPassageCarriesTheHeaderToo() throws {
        let saved = PrintHeader.isEnabled
        defer { PrintHeader.isEnabled = saved }
        PrintHeader.isEnabled = true
        let passage = PrintableTextView.laidOut(NSAttributedString(string: "before MATCH after"), width: 468)
        let text = try printedText(passage, header: ["Extended context \u{2013} corp", "Query: x"])
        #expect(text.contains("Extended context") && text.contains("MATCH"), "\(text)")
    }
}
