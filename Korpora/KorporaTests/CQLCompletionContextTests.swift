import Foundation
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
    /// full attribute list.
    @Test func emptyPrefixJustInsideABracketIsStillAnAttributeName() {
        #expect(contextTypingAtEnd("[", prefix: "") == .attributeName(prefix: ""))
    }

    /// A second attribute in the same bracket, after a completed first one -
    /// the closed quote must not leave the parser thinking it's in a value.
    @Test func attributeNameAfterACompletedValueInTheSameBracket() {
        #expect(
            contextTypingAtEnd(#"[word="fox" & ta"#, prefix: "ta")
                == .attributeName(prefix: "ta"))
    }

    /// Nested/adjacent brackets: the *last* unclosed one is what counts.
    @Test func secondBracketAfterAClosedOneIsAnAttributeName() {
        #expect(
            contextTypingAtEnd(#"[word="fox"][ta"#, prefix: "ta")
                == .attributeName(prefix: "ta"))
    }

    // MARK: - attribute values

    @Test func wordInsideAnOpenQuoteIsThatAttributesValue() {
        #expect(
            contextTypingAtEnd(#"[word="fo"#, prefix: "fo")
                == .attributeValue(attribute: "word", prefix: "fo"))
    }

    @Test func emptyPrefixJustInsideAnOpenQuoteIsStillAValue() {
        #expect(
            contextTypingAtEnd(#"[lemma=""#, prefix: "")
                == .attributeValue(attribute: "lemma", prefix: ""))
    }

    /// Whitespace and the various comparison operators between the name and
    /// the quote must not swallow the name.
    @Test func operatorAndSpacingVariantsAllYieldTheSameAttribute() {
        let variants = [#"[word="fo"#, #"[word = "fo"#, #"[word!="fo"#, #"[word != "fo"#]
        for variant in variants {
            #expect(
                contextTypingAtEnd(variant, prefix: "fo")
                    == .attributeValue(attribute: "word", prefix: "fo"),
                "variant \(variant)")
        }
    }

    /// A dotted structural attribute name is one identifier, not two.
    @Test func dottedStructuralAttributeNameIsKeptWhole() {
        #expect(
            contextTypingAtEnd(#"[doc.author="Tw"#, prefix: "Tw")
                == .attributeValue(attribute: "doc.author", prefix: "Tw"))
    }

    /// The unbracketed form the "New Subcorpus…" popover uses - value
    /// completion should still work there, since it's recognized by the
    /// unclosed quote rather than by being inside brackets.
    @Test func unbracketedAttributeValueIsStillRecognized() {
        #expect(
            contextTypingAtEnd(#"author="Tw"#, prefix: "Tw")
                == .attributeValue(attribute: "author", prefix: "Tw"))
    }

    /// A value in the *second* attribute of a bracket: the earlier
    /// completed pair's quotes are balanced, so only the live quote counts.
    @Test func valueOfASecondAttributeAfterACompletedFirstOne() {
        #expect(
            contextTypingAtEnd(#"[word="fox" & tag="N"#, prefix: "N")
                == .attributeValue(attribute: "tag", prefix: "N"))
    }

    /// An escaped quote inside a value doesn't close it - otherwise
    /// everything after it would be misread as being outside the string.
    @Test func escapedQuoteInsideAValueDoesNotCloseIt() {
        #expect(
            contextTypingAtEnd(#"[word="say \"he"#, prefix: "he")
                == .attributeValue(attribute: "word", prefix: "he"))
    }

    /// A bare string with no attribute before it: recognized as a value,
    /// but with no attribute to look values up in. The provider turns an
    /// empty attribute into "no candidates" rather than guessing.
    @Test func quotedStringWithNoAttributeYieldsAnEmptyAttribute() {
        #expect(
            contextTypingAtEnd(#"["fo"#, prefix: "fo")
                == .attributeValue(attribute: "", prefix: "fo"))
    }

    // MARK: - robustness

    /// A range past the end of the string (which a stale completion request
    /// can produce after an edit) must clamp rather than trap.
    @Test func outOfBoundsRangeIsClampedNotFatal() {
        let context = CQLCompletionContext.at(
            text: "[word", partialWordRange: NSRange(location: 99, length: 40))
        #expect(context == .attributeName(prefix: ""))
    }

    @Test func emptyTextIsAKeywordContext() {
        let context = CQLCompletionContext.at(
            text: "", partialWordRange: NSRange(location: 0, length: 0))
        #expect(context == .keyword(prefix: ""))
    }
}

/// The regex escaping that turns typed text into a literal prefix pattern.
/// Manatee matches the whole value, so completion appends ".*" - which
/// means anything the user types that looks like a metacharacter has to be
/// escaped or it silently changes the search.
struct CQLCompletionRegexEscapingTests {
    @Test func plainTextIsUnchanged() {
        #expect(CQLCompletionProvider.escapeForRegex("fox") == "fox")
    }

    @Test func dotIsEscapedSoItMatchesALiteralDot() {
        #expect(CQLCompletionProvider.escapeForRegex("a.b") == #"a\.b"#)
    }

    @Test func everyMetacharacterIsEscaped() {
        #expect(
            CQLCompletionProvider.escapeForRegex(#".*+?[](){}|^$\"#)
                == #"\.\*\+\?\[\]\(\)\{\}\|\^\$\\"#)
    }

    @Test func emptyStringStaysEmpty() {
        #expect(CQLCompletionProvider.escapeForRegex("") == "")
    }
}
