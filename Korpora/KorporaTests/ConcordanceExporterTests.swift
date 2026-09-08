import Foundation
import Testing
import ManateeKit
@testable import Korpora

@Suite struct ConcordanceExporterTests {
    private func row(
        group: Int, left: String, kwic: String, right: String,
        secondaryAttributes: [String: [String: String]] = [:]
    ) -> ConcordanceRow {
        func tokens(_ text: String) -> [KWICToken] {
            text.isEmpty ? [] : text.split(separator: " ").map {
                KWICToken(word: String($0), secondaryAttributes: secondaryAttributes[String($0)] ?? [:])
            }
        }
        let line = KWICLine(leftTokens: tokens(left), kwicTokens: tokens(kwic), rightTokens: tokens(right), position: 0)
        return ConcordanceRow(id: 0, line: line, group: group)
    }

    @Test func tabSeparatedIncludesHeaderAndAllColumns() {
        let text = ConcordanceExporter.export(
            rows: [row(group: 0, left: "the quick", kwic: "fox", right: "jumps")], format: .tabSeparated)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "Group\tLeft\tMatch\tRight")
        #expect(lines[1] == "0\tthe quick\tfox\tjumps")
    }

    @Test func commaSeparatedQuotesFieldsContainingCommas() {
        let text = ConcordanceExporter.export(
            rows: [row(group: 1, left: "hello, world", kwic: "fox", right: "jumps")], format: .commaSeparated)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[1] == "1,\"hello, world\",fox,jumps")
    }

    @Test func commaSeparatedEscapesEmbeddedQuotesByDoublingThem() {
        let text = ConcordanceExporter.export(
            rows: [row(group: 0, left: "she said \"hi\"", kwic: "fox", right: "jumps")], format: .commaSeparated)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[1] == "0,\"she said \"\"hi\"\"\",fox,jumps")
    }

    @Test func tabSeparatedReplacesEmbeddedTabsAndNewlinesRatherThanEscaping() {
        let text = ConcordanceExporter.export(
            rows: [row(group: 0, left: "a\tb\nc", kwic: "fox", right: "jumps")], format: .tabSeparated)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[1] == "0\ta b c\tfox\tjumps")
    }

    @Test func exportWithNoRowsIsJustTheHeader() {
        let text = ConcordanceExporter.export(rows: [], format: .commaSeparated)
        #expect(text == "Group,Left,Match,Right")
    }

    @Test func multipleRowsEachGetTheirOwnLine() {
        let text = ConcordanceExporter.export(
            rows: [
                row(group: 0, left: "a", kwic: "b", right: "c"),
                row(group: 2, left: "d", kwic: "e", right: "f"),
            ], format: .tabSeparated)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines.count == 3)
        #expect(lines[1] == "0\ta\tb\tc")
        #expect(lines[2] == "2\td\te\tf")
    }

    @Test func withoutInlineAttributesArgumentPlainWordsAreUnchanged() {
        let text = ConcordanceExporter.export(
            rows: [row(group: 0, left: "the quick", kwic: "fox", right: "jumps",
                       secondaryAttributes: ["fox": ["tag": "NN"]])],
            format: .commaSeparated)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[1] == "0,the quick,fox,jumps")
    }

    @Test func inlineAttributesAppendBracketedValuesAfterEachWord() {
        let text = ConcordanceExporter.export(
            rows: [row(group: 0, left: "the quick", kwic: "fox", right: "jumps",
                       secondaryAttributes: ["the": ["tag": "DT"], "quick": ["tag": "JJ"], "fox": ["tag": "NN"]])],
            format: .commaSeparated, inlineAttributes: ["tag"])
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[1] == "0,the[DT] quick[JJ],fox[NN],jumps")
    }

    @Test func inlineAttributesCombineMultipleValuesWithASlash() {
        let text = ConcordanceExporter.export(
            rows: [row(group: 0, left: "", kwic: "fox", right: "",
                       secondaryAttributes: ["fox": ["tag": "NN", "lemma": "fox"]])],
            format: .tabSeparated, inlineAttributes: ["tag", "lemma"])
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[1] == "0\t\tfox[NN/fox]\t")
    }

    @Test func inlineAttributesLeaveATokenMissingThatAttributeUnbracketed() {
        let text = ConcordanceExporter.export(
            rows: [row(group: 0, left: "", kwic: "fox jumps", right: "",
                       secondaryAttributes: ["fox": ["tag": "NN"]])],
            format: .commaSeparated, inlineAttributes: ["tag"])
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[1] == "0,,fox[NN] jumps,")
    }
}
