import Cocoa
import ManateeKit
import Testing
@testable import Korpora

/// The logic behind the New Subcorpus popover (docs/project-plan.md, 6.9),
/// with the engine replaced by fake loaders.
@MainActor @Suite struct SubcorpusValuePickerModelTests {
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

    private func model(_ data: [String: [String]], calls: Calls = Calls()) -> SubcorpusValuePickerModel {
        SubcorpusValuePickerModel(info: Self.info, loaders: .init(
            values: { attribute, limit in
                calls.values.append(attribute)
                return Array((data[attribute] ?? []).prefix(limit))
            },
            search: { attribute, text, limit in
                calls.searches.append("\(attribute):\(text)")
                return Array((data[attribute] ?? [])
                    .filter { $0.localizedCaseInsensitiveContains(text) }.prefix(limit))
            }))
    }

    @Test func startsOnTheFirstStructureAndAttribute() async {
        let m = model(["doc.genre": ["fiction", "essay"]])
        #expect(m.structure == "doc")
        #expect(m.attribute == "genre")
        #expect(m.attributes == ["genre", "year", "id"])
        await m.reload()
        #expect(m.rows == ["essay", "fiction"])
        #expect(!m.isTruncated && !m.isLoading && m.loadError == nil)
    }

    /// A list that fits is filtered here, without asking the engine again.
    @Test func aSmallListIsSearchedLocally() async {
        let calls = Calls()
        let m = model(["doc.genre": ["fiction", "essay", "Fictional letters"]], calls: calls)
        await m.reload()
        await m.search("FICTION")
        #expect(m.rows == ["fiction", "Fictional letters"])
        await m.search("")
        #expect(m.rows.count == 3)
        #expect(calls.searches.isEmpty)
        #expect(calls.values == ["doc.genre"])
    }

    @Test func numbersSortAsNumbers() async {
        let m = model(["doc.year": ["1901", "1876", "1845", "999"]])
        m.selectAttribute("year")
        await m.reload()
        #expect(m.rows == ["999", "1845", "1876", "1901"])
    }

    /// Too many values to hold: the first ones are shown, and searching asks
    /// the engine (which finds values beyond that cap).
    @Test func aBigListIsCappedAndSearchedInTheEngine() async {
        let calls = Calls()
        let many = (0..<600).map { "doc-\($0)" }
        let m = model(["doc.id": many], calls: calls)
        m.selectAttribute("id")
        await m.reload()
        #expect(m.isTruncated)
        #expect(m.rows.count == SubcorpusValuePickerModel.listCap)

        await m.search("doc-59")
        #expect(calls.searches == ["doc.id:doc-59"])
        #expect(m.rows.contains("doc-599"))  // beyond the first 500
        #expect(!m.isTruncated)
        #expect(m.rows.count == 11)  // doc-59, doc-590 ... doc-599

        await m.search("")  // back to the capped list
        #expect(m.isTruncated)
    }

    @Test func picksSurviveSwitchingAttributesAndSearching() async {
        let m = model(["doc.genre": ["fiction", "essay"], "doc.year": ["1876", "1901"]])
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
        let m = model(["doc.genre": ["fiction"]])
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
                if attribute == "doc.genre" { await gate.wait(); return ["stale"] }
                return ["1876"]
            },
            search: { _, _, _ in [] }))
        let slow = Task { await m.reload() }
        await Task.yield()
        m.selectAttribute("year")
        await m.reload()
        #expect(m.rows == ["1876"])
        await gate.release()
        await slow.value
        #expect(m.rows == ["1876"])
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
            values: { attribute, _ in attribute == "doc.genre" ? ["fiction", "essay"] : ["1876"] },
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
