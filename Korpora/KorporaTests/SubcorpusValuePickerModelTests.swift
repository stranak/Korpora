import Cocoa
import ManateeKit
import Testing
@testable import Korpora

/// The logic behind the New Subcorpus popover (docs/project-plan.md, 6.9),
/// with the engine replaced by fake loaders.
@MainActor @Suite struct SubcorpusValuePickerModelTests {
    private typealias VC = SubcorpusValuePickerModel.ValueCount

    private static let info = CorpusInfo(
        name: "t", sizeTokens: 1, attributes: ["word"],
        structures: [
            StructureInfo(name: "doc", attributes: ["genre", "year", "id"]),
            StructureInfo(name: "s", attributes: []),
        ])

    /// Loader calls, in order, for tests that care whether the engine was asked.
    final class Calls: @unchecked Sendable {
        var values: [String] = []
        var searches: [String] = []
    }

    /// Fake engine data: attribute -> value -> count. Like the engine, both
    /// loaders answer most frequent first (ties by name) and honor `limit`.
    nonisolated private static func ranked(
        _ data: [String: [String: Int]], _ attribute: String, containing text: String?, _ limit: Int
    ) -> [VC] {
        (data[attribute] ?? [:])
            .filter { text == nil || $0.key.localizedCaseInsensitiveContains(text!) }
            .map { VC(value: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
            .prefix(limit).map { $0 }
    }

    private func model(_ data: [String: [String: Int]], calls: Calls = Calls()) -> SubcorpusValuePickerModel {
        SubcorpusValuePickerModel(info: Self.info, loaders: .init(
            values: { attribute, limit in
                calls.values.append(attribute)
                return Self.ranked(data, attribute, containing: nil, limit)
            },
            search: { attribute, text, limit in
                calls.searches.append("\(attribute):\(text)")
                return Self.ranked(data, attribute, containing: text, limit)
            }))
    }

    @Test func startsOnTheFirstStructureAndAttribute() async {
        let m = model(["doc.genre": ["fiction": 2, "essay": 3]])
        #expect(m.structure == "doc")
        #expect(m.attribute == "genre")
        #expect(m.attributes == ["genre", "year", "id"])
        await m.reload()
        // Reading order for a list that fits, each value with its count.
        #expect(m.rows == [VC(value: "essay", count: 3), VC(value: "fiction", count: 2)])
        #expect(!m.isTruncated && !m.isLoading && m.loadError == nil)
    }

    /// A list that fits is filtered here, without asking the engine again.
    @Test func aSmallListIsSearchedLocally() async {
        let calls = Calls()
        let m = model(["doc.genre": ["fiction": 5, "essay": 3, "Fictional letters": 1]], calls: calls)
        await m.reload()
        await m.search("FICTION")
        #expect(m.rows == [VC(value: "fiction", count: 5), VC(value: "Fictional letters", count: 1)])
        await m.search("")
        #expect(m.rows.count == 3)
        #expect(calls.searches.isEmpty)
        #expect(calls.values == ["doc.genre"])
    }

    @Test func numbersSortAsNumbers() async {
        let m = model(["doc.year": ["1901": 1, "1876": 4, "1845": 2, "999": 9]])
        m.selectAttribute("year")
        await m.reload()
        #expect(m.rows.map(\.value) == ["999", "1845", "1876", "1901"])
        #expect(m.rows.map(\.count) == [9, 2, 4, 1])
    }

    /// Too many values to hold: the most frequent are shown, in frequency
    /// order, and searching asks the engine (which finds values beyond that
    /// cap, also most frequent first).
    @Test func aBigListIsCappedAndSearchedInTheEngine() async {
        let calls = Calls()
        // doc-0 is the most frequent, doc-599 the least.
        let many = Dictionary(uniqueKeysWithValues: (0..<600).map { ("doc-\($0)", 1000 - $0) })
        let m = model(["doc.id": many], calls: calls)
        m.selectAttribute("id")
        await m.reload()
        #expect(m.isTruncated)
        #expect(m.rows.count == SubcorpusValuePickerModel.listCap)
        #expect(m.rows.first == VC(value: "doc-0", count: 1000))
        #expect(m.rows.last == VC(value: "doc-499", count: 501))

        await m.search("doc-59")
        #expect(calls.searches == ["doc.id:doc-59"])
        #expect(m.rows.first == VC(value: "doc-59", count: 941))
        #expect(m.rows.last == VC(value: "doc-599", count: 401))  // beyond the first 500
        #expect(!m.isTruncated)
        #expect(m.rows.count == 11)  // doc-59, doc-590 ... doc-599

        await m.search("")  // back to the capped list
        #expect(m.isTruncated)
        #expect(m.rows.first?.value == "doc-0")
    }

    @Test func picksSurviveSwitchingAttributesAndSearching() async {
        let m = model(["doc.genre": ["fiction": 2, "essay": 3], "doc.year": ["1876": 2, "1901": 3]])
        await m.reload()
        m.toggle("fiction")
        m.toggle("essay")
        m.selectAttribute("year")
        await m.reload()
        #expect(!m.isSelected("1876"))
        m.toggle("1876")
        await m.search("18")
        #expect(m.isSelected("1876"))
        m.selectAttribute("genre")
        await m.reload()
        #expect(m.isSelected("fiction") && m.isSelected("essay"))
        #expect(m.selectedCount == 3)
        #expect(m.restriction.query == #"(genre="essay"|genre="fiction") & year="1876""#)

        m.toggle("essay")
        #expect(m.restriction.query == #"genre="fiction" & year="1876""#)
        m.clearSelection()
        #expect(m.selectedCount == 0 && m.restriction.query.isEmpty)
    }

    @Test func changingTheStructureStartsOver() async {
        let m = model(["doc.genre": ["fiction": 1]])
        await m.reload()
        m.toggle("fiction")
        m.selectStructure("s")
        #expect(m.structure == "s" && m.attribute == nil && m.attributes.isEmpty)
        #expect(m.rows.isEmpty && !m.isLoading)
        #expect(m.selectedCount == 0)
        await m.reload()  // nothing to load, and no error
        #expect(m.loadError == nil)
        m.selectStructure("nonexistent")
        #expect(m.structure == "s")
    }

    @Test func aFailingLoaderIsReported() async {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        let m = SubcorpusValuePickerModel(info: Self.info, loaders: .init(
            values: { _, _ in throw Boom() }, search: { _, _, _ in throw Boom() }))
        await m.reload()
        #expect(m.loadError == "boom")
        #expect(m.rows.isEmpty && !m.isLoading)
    }

    /// The user switches attribute while the first list is still coming: the
    /// late answer must not replace the current one.
    @Test func aLateAnswerToAnOldQuestionIsDropped() async {
        actor Gate {
            var open: CheckedContinuation<Void, Never>?
            func wait() async { await withCheckedContinuation { open = $0 } }
            func release() { open?.resume(); open = nil }
        }
        let gate = Gate()
        let m = SubcorpusValuePickerModel(info: Self.info, loaders: .init(
            values: { attribute, _ in
                if attribute == "doc.genre" { await gate.wait(); return [VC(value: "stale", count: 1)] }
                return [VC(value: "1876", count: 2)]
            },
            search: { _, _, _ in [] }))
        let slow = Task { await m.reload() }
        await Task.yield()
        m.selectAttribute("year")
        await m.reload()
        #expect(m.rows == [VC(value: "1876", count: 2)])
        await gate.release()
        await slow.value
        #expect(m.rows == [VC(value: "1876", count: 2)])
        #expect(!m.isLoading)
    }
}

/// The popover itself, driven the way a click would: layout at its real
/// size, the Create button's rules, and what `onCreate` receives.
@MainActor @Suite struct NewSubcorpusPopoverTests {
    private static let info = CorpusInfo(
        name: "t", sizeTokens: 1, attributes: ["word"],
        structures: [
            StructureInfo(name: "doc", attributes: ["genre", "year"]),
            StructureInfo(name: "s", attributes: []),
        ])

    /// Waits for the load `viewDidLoad` starts. (Starting a second one would
    /// supersede it: the model drops answers to old questions.)
    private func settle(_ controller: NewSubcorpusPopoverController) async {
        for _ in 0..<1000 where controller.model.isLoading || controller.model.rows.isEmpty && controller.model.loadError == nil && controller.model.attribute != nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func popover(info: CorpusInfo = info) async -> NewSubcorpusPopoverController {
        let controller = NewSubcorpusPopoverController()
        controller.corpusInfo = info
        controller.loaders = .init(
            values: { attribute, _ in
                attribute == "doc.genre"
                    ? [.init(value: "fiction", count: 2), .init(value: "essay", count: 3)]
                    : [.init(value: "1876", count: 2)]
            },
            search: { _, _, _ in [] })
        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()
        await settle(controller)
        return controller
    }

    @Test func layoutGivesTheListRoomAndShowsValuesMode() async {
        let controller = await popover()
        let root = controller.view
        #expect(root.frame.size == NSSize(width: 420, height: 440))
        #expect(!controller.valuesContainer.isHidden)
        #expect(controller.cqlContainer.isHidden)
        // The list must not collapse: it's the point of the popover.
        #expect(controller.scrollView.frame.height >= 120)
        #expect(controller.scrollView.frame.width >= 380)
        #expect(root.bounds.contains(controller.createButton.frame))
        #expect(controller.scrollView.frame.maxY <= controller.valuesContainer.frame.maxY)
    }

    private func cell(_ controller: NewSubcorpusPopoverController, row: Int) throws -> (NSButton, NSTextField) {
        let table = try #require(controller.scrollView.documentView as? NSTableView)
        let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
        let checkbox = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        let count = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
        return (checkbox, count)
    }

    /// Each row: the value with how many <doc>s have it; clicking picks it.
    @Test func rowsShowCountsAndClickingPicks() async throws {
        let controller = await popover()
        let (essay, essayCount) = try cell(controller, row: 0)
        let (fiction, fictionCount) = try cell(controller, row: 1)
        #expect(essay.title == "essay" && essayCount.stringValue == "3")
        #expect(fiction.title == "fiction" && fictionCount.stringValue == "2")
        #expect(essayCount.toolTip == "3 doc with this value")

        essay.performClick(nil)
        #expect(controller.model.isSelected("essay") && !controller.model.isSelected("fiction"))
        #expect(controller.model.restriction.query == #"genre="essay""#)
    }

    @Test func createNeedsANameAndAPick() async throws {
        let controller = await popover()
        #expect(!controller.createButton.isEnabled)
        controller.nameField.stringValue = "Fiction"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.nameField))
        #expect(!controller.createButton.isEnabled)  // named, nothing picked

        controller.model.toggle("fiction")
        controller.nameField.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.nameField))
        #expect(!controller.createButton.isEnabled)  // picked, unnamed
    }

    @Test func createHandsOverTheGeneratedRestriction() async throws {
        let controller = await popover()
        var created: (String, String, String)?
        controller.onCreate = { created = ($0, $1, $2) }
        controller.nameField.stringValue = "  Fiction and essays  "
        controller.model.toggle("fiction")
        controller.model.toggle("essay")
        controller.createButton.isEnabled = true
        controller.createButton.performClick(nil)
        let (name, structure, query) = try #require(created)
        #expect(name == "Fiction and essays")
        #expect(structure == "doc")
        #expect(query == #"(genre="essay"|genre="fiction")"#)
    }

    /// The typed restriction still works, and starts from the picks.
    @Test func cqlModeStartsFromThePicksAndCreatesWhatIsTyped() async throws {
        let controller = await popover()
        controller.model.toggle("fiction")
        controller.modeControl.selectedSegment = 1
        _ = controller.modeControl.sendAction(controller.modeControl.action, to: controller.modeControl.target)
        #expect(controller.valuesContainer.isHidden && !controller.cqlContainer.isHidden)
        #expect(controller.queryField.text == #"genre="fiction""#)

        var created: (String, String, String)?
        controller.onCreate = { created = ($0, $1, $2) }
        controller.queryField.text = #"genre="fiction" & year!="1901""#
        controller.nameField.stringValue = "typed"
        controller.createButton.isEnabled = true
        controller.createButton.performClick(nil)
        #expect(created?.2 == #"genre="fiction" & year!="1901""#)
    }

    /// A corpus with no structure attributes can't be picked from; the popover
    /// opens where typing is possible.
    @Test func withoutAttributesItOpensInCQLMode() async {
        let bare = CorpusInfo(name: "t", sizeTokens: 1, attributes: ["word"],
                              structures: [StructureInfo(name: "s", attributes: [])])
        let controller = await popover(info: bare)
        #expect(controller.valuesContainer.isHidden && !controller.cqlContainer.isHidden)
        #expect(controller.modeControl.selectedSegment == 1)
    }

    /// No corpus to read from (or one that won't open): reported, not a crash.
    @Test func unreadableCorpusIsReported() async {
        let controller = NewSubcorpusPopoverController()
        controller.corpusInfo = Self.info
        controller.corpusName = "definitely-not-a-corpus-\(UUID().uuidString)"
        _ = controller.view
        await settle(controller)
        #expect(controller.model.loadError != nil)
        #expect(controller.model.rows.isEmpty)
    }
}
