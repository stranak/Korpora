import Foundation
import ManateeKit
import Testing

@testable import Korpora

/// Phase 6.8: where the caret is decides what gets completed. This is the
/// pure half of that feature - it takes a string and a range and returns a
/// case, so every position rule is testable without a window, a corpus, or
/// AppKit's completion machinery.
///
/// The ranges below are what `NSTextView` hands
/// `completions(forPartialWordRange:)`: the range of the partial *word*
/// under the caret, which excludes `[`, `=` and `"` since those aren't
/// word characters.
struct CQLCompletionContextTests {
    /// The partial-word range for a query whose caret sits at the very end,
    /// with `prefix` as the word being typed - the normal typing case.
    private func contextTypingAtEnd(_ text: String, prefix: String) -> CQLCompletionContext {
        let start = (text as NSString).length - (prefix as NSString).length
        return CQLCompletionContext.at(
            text: text, partialWordRange: NSRange(location: start, length: (prefix as NSString).length))
    }

    // MARK: - keywords

    @Test func plainWordOutsideBracketsIsAKeyword() {
        #expect(contextTypingAtEnd("wit", prefix: "wit") == .keyword(prefix: "wit"))
    }

    @Test func wordAfterAClosedBracketIsAKeyword() {
        #expect(contextTypingAtEnd(#"[word="fox"] wit"#, prefix: "wit") == .keyword(prefix: "wit"))
    }

    // MARK: - attribute names

    @Test func wordJustInsideAnOpenBracketIsAnAttributeName() {
        #expect(contextTypingAtEnd("[lem", prefix: "lem") == .attributeName(prefix: "lem"))
    }

    /// Right after `[` there's no partial word yet - an empty prefix, which
    /// must still classify as an attribute name so the popup can offer the
    /// whole attribute list.
    @Test func emptyPrefixJustInsideABracketIsStillAnAttributeName() {
        #expect(contextTypingAtEnd("[", prefix: "") == .attributeName(prefix: ""))
    }

    /// A second attribute in the same bracket, after a completed first one:
    /// the closed quote must not leave the parser thinking it's still in a
    /// value, and the `&` must not read as a finished identifier.
    @Test func attributeNameAfterACompletedValueInTheSameBracket() {
        #expect(
            contextTypingAtEnd(#"[word="fox" & ta"#, prefix: "ta")
                == .attributeName(prefix: "ta"))
    }

    @Test func emptyPrefixAfterABooleanOperatorIsAnAttributeName() {
        #expect(contextTypingAtEnd(#"[word="fox" & "#, prefix: "") == .attributeName(prefix: ""))
    }

    /// Nested/adjacent brackets: the *last* unclosed one is what counts.
    @Test func secondBracketAfterAClosedOneIsAnAttributeName() {
        #expect(
            contextTypingAtEnd(#"[word="fox"][ta"#, prefix: "ta")
                == .attributeName(prefix: "ta"))
    }

    // MARK: - comparison operators

    /// Right after a finished attribute name, an operator is the only thing
    /// that can legally come next. There's no partial word to type it into,
    /// which is exactly why offering it as a completion is worth doing.
    @Test func emptyPrefixAfterAnAttributeNameOffersOperators() {
        #expect(contextTypingAtEnd("[word ", prefix: "") == .comparisonOperator(prefix: ""))
    }

    @Test func operatorPositionIsFoundWithoutASpaceToo() {
        #expect(contextTypingAtEnd("[word", prefix: "") == .comparisonOperator(prefix: ""))
    }

    @Test func operatorPositionAfterADottedStructuralName() {
        #expect(contextTypingAtEnd("[doc.author ", prefix: "") == .comparisonOperator(prefix: ""))
    }

    /// Once the operator is typed, we're no longer in operator position -
    /// `=` is not an identifier character.
    @Test func afterTheOperatorItselfIsNotOperatorPosition() {
        #expect(contextTypingAtEnd("[word=", prefix: "") == .attributeName(prefix: ""))
    }

    // MARK: - inside a quoted value: nothing

    /// Values are corpus data, not language - 6.8 deliberately doesn't
    /// complete them, and completing keywords inside a string would be
    /// actively wrong.
    @Test func insideAnOpenQuoteNothingIsOffered() {
        #expect(contextTypingAtEnd(#"[word="fo"#, prefix: "fo") == .quotedValue)
    }

    @Test func emptyPrefixJustInsideAnOpenQuoteOffersNothing() {
        #expect(contextTypingAtEnd(#"[lemma=""#, prefix: "") == .quotedValue)
    }

    /// An escaped quote inside a value doesn't close it - otherwise
    /// everything after it would be misread as language.
    @Test func escapedQuoteInsideAValueDoesNotCloseIt() {
        #expect(contextTypingAtEnd(#"[word="say \"he"#, prefix: "he") == .quotedValue)
    }

    /// The unbracketed form the "New Subcorpus…" popover uses is still
    /// recognized as a value, so nothing is offered there either.
    @Test func unbracketedQuotedValueOffersNothing() {
        #expect(contextTypingAtEnd(#"author="Tw"#, prefix: "Tw") == .quotedValue)
    }

    // MARK: - robustness

    /// A range past the end of the string (which a stale completion request
    /// can produce after an edit) must clamp rather than trap.
    @Test func outOfBoundsRangeIsClampedNotFatal() {
        let context = CQLCompletionContext.at(
            text: "[word", partialWordRange: NSRange(location: 99, length: 40))
        #expect(context == .comparisonOperator(prefix: ""))
    }

    @Test func emptyTextIsAKeywordContext() {
        let context = CQLCompletionContext.at(
            text: "", partialWordRange: NSRange(location: 0, length: 0))
        #expect(context == .keyword(prefix: ""))
    }
}

/// The candidate lists themselves - in particular that structural
/// attributes are offered in the dotted form CQL actually accepts.
struct CQLCompletionCandidateTests {
    private let info = CorpusInfo(
        name: "test", sizeTokens: 17, attributes: ["word", "lemma", "tag"],
        structures: [
            StructureInfo(name: "doc", attributes: ["id", "author"]),
            StructureInfo(name: "s", attributes: []),
        ])

    @Test func bothPositionalAndStructuralNamesAreOffered() {
        let names = CQLCompletionProvider.attributeNames(from: info)
        #expect(names == ["doc.author", "doc.id", "lemma", "tag", "word"])
    }

    /// A structure with no attributes of its own contributes nothing -
    /// there's no `s.` to complete to.
    @Test func aStructureWithNoAttributesContributesNothing() {
        let names = CQLCompletionProvider.attributeNames(from: info)
        #expect(!names.contains { $0.hasPrefix("s.") })
    }

    @Test func emptyPrefixOffersEverything() {
        let all = CQLCompletionProvider.matching(["word", "lemma"], prefix: "")
        #expect(all == ["word", "lemma"])
    }

    @Test func prefixMatchingIsCaseInsensitive() {
        let matches = CQLCompletionProvider.matching(["doc.author", "doc.id", "word"], prefix: "DOC.")
        #expect(matches == ["doc.author", "doc.id"])
    }

    @Test func noMatchesIsNilSoAppKitShowsNoPopup() {
        #expect(CQLCompletionProvider.matching(["word"], prefix: "zz") == nil)
    }
}
