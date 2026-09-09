import Foundation
import Testing

@testable import Korpora

/// Phase 6.8: brackets and quotes auto-close, and typing a closer that's
/// already there steps over it instead of doubling it. Pure rules over
/// (text, selection, typed character), so they're testable without a text
/// view - the caret positions are the whole substance of the feature.
struct CQLAutoPairingTests {
    /// Typing `input` with the caret at the end of `text`.
    private func typing(_ input: String, atEndOf text: String) -> CQLAutoPairing.Action {
        CQLAutoPairing.action(
            forTyping: input, text: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0))
    }

    private func typing(_ input: String, in text: String, caret: Int) -> CQLAutoPairing.Action {
        CQLAutoPairing.action(
            forTyping: input, text: text, selectedRange: NSRange(location: caret, length: 0))
    }

    // MARK: - opening

    /// The caret offset is what matters: 1 puts it *between* the halves, so
    /// the next keystroke goes inside the brackets.
    @Test func typingAnOpenBracketInsertsThePairWithTheCaretInside() {
        #expect(typing("[", atEndOf: "") == .insert(text: "[]", caretOffset: 1))
    }

    @Test func typingAQuoteInsertsThePairWithTheCaretInside() {
        #expect(typing("\"", atEndOf: "[word=") == .insert(text: "\"\"", caretOffset: 1))
    }

    @Test func parensAndAngleBracketsPairToo() {
        #expect(typing("(", atEndOf: "") == .insert(text: "()", caretOffset: 1))
        #expect(typing("<", atEndOf: "") == .insert(text: "<>", caretOffset: 1))
    }

    // MARK: - stepping over a closer

    @Test func typingAClosingBracketThatIsAlreadyThereStepsOverIt() {
        #expect(typing("]", in: "[word]", caret: 5) == .moveOver)
    }

    /// The case that makes `"` awkward: the same character opens and
    /// closes, so which job it does depends entirely on what's to the
    /// right. Sitting just before the closing quote of `"fox"`, typing `"`
    /// must finish the string rather than start a new one.
    @Test func typingAQuoteBeforeAnExistingQuoteStepsOverIt() {
        #expect(typing("\"", in: #"[word="fox"]"#, caret: 10) == .moveOver)
    }

    /// A closer that isn't the next character is just a normal keystroke -
    /// closing a bracket the auto-pairing didn't create must still work.
    @Test func typingAClosingBracketWithSomethingElseNextPassesThrough() {
        #expect(typing("]", in: "[word ", caret: 6) == .passThrough)
    }

    @Test func typingAClosingBracketAtTheVeryEndPassesThrough() {
        #expect(typing("]", atEndOf: "[word") == .passThrough)
    }

    // MARK: - wrapping a selection

    /// Selecting text and typing an opener wraps it rather than replacing
    /// it - the one case where the caret offset isn't 1, since the caret
    /// goes after the wrapped text.
    @Test func typingAnOpenerWithASelectionWrapsIt() {
        let action = CQLAutoPairing.action(
            forTyping: "\"", text: "fox", selectedRange: NSRange(location: 0, length: 3))
        #expect(action == .insert(text: "\"fox\"", caretOffset: 4))
    }

    @Test func wrappingWorksForBracketsToo() {
        let action = CQLAutoPairing.action(
            forTyping: "[", text: #"word="fox""#, selectedRange: NSRange(location: 0, length: 10))
        #expect(action == .insert(text: #"[word="fox"]"#, caretOffset: 11))
    }

    // MARK: - everything else is untouched

    @Test func ordinaryCharactersPassThrough() {
        #expect(typing("w", atEndOf: "[") == .passThrough)
        #expect(typing("=", atEndOf: "[word") == .passThrough)
    }

    /// Multi-character input - a paste, or a dead-key/IME commit - is never
    /// auto-paired: the rules are about single keystrokes, and guessing at
    /// a pasted fragment would corrupt it.
    @Test func multiCharacterInputPassesThrough() {
        #expect(typing("[word]", atEndOf: "") == .passThrough)
        #expect(typing("", atEndOf: "") == .passThrough)
    }

    // MARK: - backspacing an empty pair

    @Test func backspaceInsideAnEmptyPairDeletesBothHalves() {
        #expect(CQLAutoPairing.deletesEmptyPair(
            text: "[]", selectedRange: NSRange(location: 1, length: 0)))
        #expect(CQLAutoPairing.deletesEmptyPair(
            text: "\"\"", selectedRange: NSRange(location: 1, length: 0)))
    }

    /// A pair with content between the halves is not empty - backspace
    /// there must delete one character, not swallow the brackets.
    @Test func backspaceInANonEmptyPairIsOrdinary() {
        #expect(!CQLAutoPairing.deletesEmptyPair(
            text: "[word]", selectedRange: NSRange(location: 5, length: 0)))
    }

    /// Mismatched neighbours aren't a pair.
    @Test func backspaceBetweenMismatchedCharactersIsOrdinary() {
        #expect(!CQLAutoPairing.deletesEmptyPair(
            text: "[)", selectedRange: NSRange(location: 1, length: 0)))
    }

    @Test func backspaceAtTheEdgesIsOrdinary() {
        #expect(!CQLAutoPairing.deletesEmptyPair(
            text: "[]", selectedRange: NSRange(location: 0, length: 0)))
        #expect(!CQLAutoPairing.deletesEmptyPair(
            text: "[]", selectedRange: NSRange(location: 2, length: 0)))
    }

    /// With a selection, backspace deletes the selection - the empty-pair
    /// rule must not hijack it.
    @Test func backspaceWithASelectionIsOrdinary() {
        #expect(!CQLAutoPairing.deletesEmptyPair(
            text: "[]", selectedRange: NSRange(location: 0, length: 2)))
    }
}
