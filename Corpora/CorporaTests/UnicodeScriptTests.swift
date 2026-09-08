import Testing
@testable import Corpora

@Suite struct UnicodeScriptTests {
    @Test func dominantClassifiesEachCoveredScript() {
        #expect(UnicodeScript.dominant(in: "fox") == .latin)
        #expect(UnicodeScript.dominant(in: "Über") == .latin)
        #expect(UnicodeScript.dominant(in: "быть") == .cyrillic)
        #expect(UnicodeScript.dominant(in: "λόγος") == .greek)
        #expect(UnicodeScript.dominant(in: "שלום") == .hebrew)
        #expect(UnicodeScript.dominant(in: "مرحبا") == .arabic)
        #expect(UnicodeScript.dominant(in: "日本語") == .cjk)
    }

    @Test func dominantFallsBackToOtherForDigitsPunctuationAndSpaces() {
        #expect(UnicodeScript.dominant(in: "123") == .other)
        #expect(UnicodeScript.dominant(in: "!?") == .other)
        #expect(UnicodeScript.dominant(in: " ") == .other)
        #expect(UnicodeScript.dominant(in: "") == .other)
    }

    @Test func dominantUsesTheFirstNonOtherScalarInAMixedToken() {
        // "123fox" - digits first, but "fox" is what actually determines
        // a real font choice, so scanning must continue past them rather
        // than stopping at the first (non-classifying) scalar.
        #expect(UnicodeScript.dominant(in: "123fox") == .latin)
        #expect(UnicodeScript.dominant(in: "123быть") == .cyrillic)
    }
}
