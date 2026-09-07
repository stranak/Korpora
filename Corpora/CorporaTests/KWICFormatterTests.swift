import Foundation
import Testing
import ManateeKit
@testable import Corpora

@Suite struct KWICFormatterTests {
    private let tokens = [
        KWICToken(word: "the", secondaryAttributes: ["lemma": "the", "tag": "DT"]),
        KWICToken(word: "fox", secondaryAttributes: ["lemma": "fox", "tag": "NN"]),
    ]

    @Test func displayLineIsPerTokenWordSegmentsWithoutInlineAttributes() {
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: [], tooltipAttributes: [])
        #expect(line.segments == [
            KWICDisplaySegment(text: "the", kind: .word),
            KWICDisplaySegment(text: " ", kind: .word),
            KWICDisplaySegment(text: "fox", kind: .word),
        ])
        #expect(line.tokenTooltips.isEmpty)
    }

    @Test func displayLineAppendsInlineAttributesAsSecondarySegments() {
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: ["tag"], tooltipAttributes: [])
        #expect(line.segments == [
            KWICDisplaySegment(text: "the", kind: .word),
            KWICDisplaySegment(text: "/DT", kind: .secondaryAttribute),
            KWICDisplaySegment(text: " ", kind: .word),
            KWICDisplaySegment(text: "fox", kind: .word),
            KWICDisplaySegment(text: "/NN", kind: .secondaryAttribute),
        ])
    }

    @Test func displayLineCombinesMultipleInlineAttributesInOneSecondarySegment() {
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: ["lemma", "tag"], tooltipAttributes: [])
        #expect(line.segments.filter { $0.kind == .secondaryAttribute }.map(\.text) == ["/the/DT", "/fox/NN"])
    }

    @Test func displayLineSkipsSecondarySegmentForATokenMissingTheRequestedAttribute() {
        let partial = [KWICToken(word: "the", secondaryAttributes: [:])]
        let line = KWICFormatter.displayLine(for: partial, inlineAttributes: ["tag"], tooltipAttributes: [])
        #expect(line.segments == [KWICDisplaySegment(text: "the", kind: .word)])
    }

    @Test func displayLineHasNoTooltipsWithoutTooltipAttributes() {
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: [], tooltipAttributes: [])
        #expect(line.tokenTooltips.isEmpty)
    }

    @Test func displayLineTooltipsAreOnePerTokenNotOneForTheWholeLine() {
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: [], tooltipAttributes: ["lemma", "tag"])
        #expect(line.tokenTooltips.count == 2)
        #expect(line.tokenTooltips[0].text == "lemma: the, tag: DT")
        #expect(line.tokenTooltips[1].text == "lemma: fox, tag: NN")
    }

    @Test func tooltipSegmentRangesPointAtThatTokensOwnSegmentsOnly() {
        // With "tag" both inline and on hover, each token contributes 2
        // segments (word + its "/tag" suffix) - the tooltip's range must
        // cover only *that* token's 2 segments, not the whole line's.
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: ["tag"], tooltipAttributes: ["tag"])
        #expect(line.segments.count == 5) // the, /DT, " ", fox, /NN
        #expect(line.tokenTooltips.map(\.segmentRange) == [0..<2, 3..<5])
    }

    @Test func inlineAndTooltipAttributesCanOverlapOrDiffer() {
        // The combination the user specifically asked for: "tag" inline,
        // "lemma" only on hover, at the same time - not mutually exclusive.
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: ["tag"], tooltipAttributes: ["lemma"])
        #expect(line.segments.filter { $0.kind == .secondaryAttribute }.map(\.text) == ["/DT", "/NN"])
        #expect(line.tokenTooltips.map(\.text) == ["lemma: the", "lemma: fox"])
    }
}
