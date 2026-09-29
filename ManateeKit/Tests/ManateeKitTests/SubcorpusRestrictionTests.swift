import XCTest

@testable import ManateeKit

/// Phase 6.9: restrictions built from picked values. The engine tests build
/// real subcorpora, because what matters is that the generated string
/// selects exactly the documents picked - including values full of regex
/// metacharacters, quotes and backslashes.
final class SubcorpusRestrictionTests: XCTestCase {
    private typealias R = SubcorpusRestriction
    private typealias S = SubcorpusRestriction.Selection

    // MARK: Building the string

    func testEmptyRestrictionHasNoQuery() {
        XCTAssertEqual(R().query, "")
        XCTAssertTrue(R(selections: [S(attribute: "genre", values: [])]).isEmpty)
    }

    func testOneValue() {
        XCTAssertEqual(R(selections: [S(attribute: "genre", values: ["fiction"])]).query, #"genre="fiction""#)
    }

    func testSeveralValuesOfOneAttributeAreAlternatives() {
        XCTAssertEqual(R(selections: [S(attribute: "genre", values: ["fiction", "essay"])]).query,
                       #"(genre="fiction"|genre="essay")"#)
    }

    func testAttributesAreCombinedWithAnd() {
        let restriction = R(selections: [
            S(attribute: "genre", values: ["fiction", "essay"]),
            S(attribute: "empty", values: []),
            S(attribute: "year", values: ["1876"]),
        ])
        XCTAssertEqual(restriction.query, #"(genre="fiction"|genre="essay") & year="1876""#)
    }

    func testRegexMetacharactersAreEscapedThenQuoted() {
        XCTAssertEqual(R.regexEscaped("Smith (Jr.)"), #"Smith \(Jr\.\)"#)
        XCTAssertEqual(R.literal("Smith (Jr.)"), #""Smith \\(Jr\\.\\)""#)
        // A quote is only quoted, not regex-escaped; a backslash is both.
        XCTAssertEqual(R.literal(#"say "hi""#), #""say \"hi\"""#)
        XCTAssertEqual(R.literal(#"a\b"#), #""a\\\\b""#)
        XCTAssertEqual(R.literal("plain text, ünïcode"), "\"plain text, ünïcode\"")
    }

    func testContainsPattern() {
        XCTAssertEqual(R.containsPattern("a.b"), #".*a\.b.*"#)
    }

    // MARK: Against the engine

    private static var fixture: TestCorpusFixture!

    private static let names = ["Twain", "Poe", "Smith (Jr.)", "Smith Jrx", #"a+b "q" \x"#]
    private static let genres = ["fiction", "fiction", "essay", "essay", "essay"]
    private static let years = ["1876", "1845", "1901", "1901", "1876"]

    override class func setUp() {
        super.setUp()
        var vertical = ""
        for i in 0..<names.count {
            // Attribute values in a vertical file are XML-attribute-escaped.
            let author = names[i].replacingOccurrences(of: "\"", with: "&quot;")
            vertical += "<doc author=\"\(author)\" genre=\"\(genres[i])\" year=\"\(years[i])\">\n<s>\n"
            vertical += "word\(i)\tword\(i)\tNN\nend\tend\tNN\n</s>\n</doc>\n"
        }
        do {
            fixture = try TestCorpusFixture.build(
                corpusName: "mkitrestrict", vertical: vertical,
                docAttributes: ["author", "genre", "year"])
        } catch {
            XCTFail("failed to build fixture: \(error)")
        }
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: SubcorpusStore.directory(for: fixture.corpusName))
        fixture?.cleanUp()
        fixture = nil
        super.tearDown()
    }

    /// Each document is two tokens, so a subcorpus's size is 2 × its documents.
    private func documents(matching restriction: R, name: String) async throws -> Int {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let path = try await corpus.createSubcorpus(named: name, structure: "doc", query: restriction.query)
        return try await corpus.openSubcorpus(atPath: path).size / 2
    }

    func testOneValueSelectsItsDocuments() async throws {
        let n = try await documents(matching: R(selections: [S(attribute: "genre", values: ["fiction"])]), name: "one")
        XCTAssertEqual(n, 2)
    }

    func testSeveralValuesOfOneAttributeAreUnioned() async throws {
        let n = try await documents(
            matching: R(selections: [S(attribute: "author", values: ["Twain", "Poe"])]), name: "or")
        XCTAssertEqual(n, 2)
    }

    /// OR within an attribute, AND across attributes: 1901 essays by either
    /// of two authors is one document, not the union of the attributes.
    func testAttributesNarrowEachOther() async throws {
        let restriction = R(selections: [
            S(attribute: "genre", values: ["essay", "fiction"]),
            S(attribute: "year", values: ["1876"]),
        ])
        let n = try await documents(matching: restriction, name: "and")
        XCTAssertEqual(n, 2)  // Twain (fiction, 1876) and the a+b author (essay, 1876)
    }

    /// The values the engine actually stores for `author`, which is what a
    /// picker offers. (`encodevert` keeps XML entities in attribute values
    /// as written: `&quot;` stays `&quot;`.)
    private func storedAuthors() async throws -> [String] {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        return try await corpus.attributeValues(attribute: "doc.author")
    }

    /// The reason values are regex-escaped: `Smith (Jr.)` as a raw regex
    /// would match "Smith Jrx" and not itself.
    func testValuesWithRegexMetacharactersMatchOnlyThemselves() async throws {
        let n = try await documents(
            matching: R(selections: [S(attribute: "author", values: ["Smith (Jr.)"])]), name: "meta")
        XCTAssertEqual(n, 1)
        let tricky = try await storedAuthors().first { $0.contains("+") }
        XCTAssertNotNil(tricky)
        let m = try await documents(
            matching: R(selections: [S(attribute: "author", values: [tricky ?? ""])]), name: "tricky")
        XCTAssertEqual(m, 1)
    }

    func testEveryStoredValueSelectsExactlyItsOwnDocument() async throws {
        let stored = try await storedAuthors()
        XCTAssertEqual(stored.count, Self.names.count)
        for (i, value) in stored.enumerated() {
            let n = try await documents(
                matching: R(selections: [S(attribute: "author", values: [value])]), name: "each\(i)")
            XCTAssertEqual(n, 1, "author \(value)")
        }
    }

    /// What the picker's numbers mean: for a structure attribute, how many
    /// structure instances (here documents) have the value - not tokens.
    /// (Each fixture document has two tokens, so tokens would read 6 and 4.)
    func testStructureAttributeFrequenciesCountDocuments() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let genres = try await corpus.topAttributeValues(attribute: "doc.genre", limit: 10)
        XCTAssertEqual(genres.map(\.value), ["essay", "fiction"])
        XCTAssertEqual(genres.map(\.frequency), [3, 2])
        let years = try await corpus.topAttributeValues(attribute: "doc.year", limit: 10)
        XCTAssertEqual(years.map(\.frequency), [2, 2, 1])  // 1876 and 1901 twice, 1845 once
        XCTAssertEqual(Set(years.map(\.value)), ["1845", "1876", "1901"])
    }

    /// The search behind a big attribute's list: matches only, most
    /// frequent first, with counts.
    func testCountedSearchReturnsMatchesMostFrequentFirst() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let smiths = try await corpus.topAttributeValues(
            attribute: "doc.author", matching: R.containsPattern("smith"), ignoreCase: true, limit: 10)
        XCTAssertEqual(Set(smiths.map(\.value)), ["Smith (Jr.)", "Smith Jrx"])
        XCTAssertEqual(smiths.map(\.frequency), [1, 1])
        // Case-sensitive: nothing matches "smith" in lowercase.
        let none = try await corpus.topAttributeValues(
            attribute: "doc.author", matching: R.containsPattern("smith"), ignoreCase: false, limit: 10)
        XCTAssertEqual(none.count, 0)
        // A regex metacharacter in the search text is literal.
        let paren = try await corpus.topAttributeValues(
            attribute: "doc.author", matching: R.containsPattern("(Jr"), ignoreCase: true, limit: 10)
        XCTAssertEqual(paren.map(\.value), ["Smith (Jr.)"])
        // The limit keeps the most frequent: years 1876/1901 (2 each) before 1845.
        let top = try await corpus.topAttributeValues(
            attribute: "doc.year", matching: ".*", ignoreCase: false, limit: 2)
        XCTAssertEqual(top.map(\.frequency), [2, 2])
    }

    /// The lists the picker shows: every distinct value of an attribute
    /// (capped), and a "contains" search over them.
    func testTheValueListsAreWhatThePickerNeeds() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let genres = try await corpus.attributeValues(
            attribute: "doc.genre", matching: ".*", ignoreCase: false, limit: 10)
        XCTAssertEqual(Set(genres), ["essay", "fiction"])

        let smiths = try await corpus.attributeValues(
            attribute: "doc.author", matching: R.containsPattern("Smith (J"), ignoreCase: true, limit: 10)
        XCTAssertEqual(smiths, ["Smith (Jr.)"])
        let loose = try await corpus.attributeValues(
            attribute: "doc.author", matching: R.containsPattern("smith"), ignoreCase: true, limit: 10)
        XCTAssertEqual(Set(loose), ["Smith (Jr.)", "Smith Jrx"])
    }
}
