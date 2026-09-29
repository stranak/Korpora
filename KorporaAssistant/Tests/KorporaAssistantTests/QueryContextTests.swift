import Foundation
import ManateeKit
import Testing
@testable import KorporaAssistant

/// Hand-made corpus profiles shaped like the real corpora the assistant
/// meets: UD English EWT (`upos`), the EU DGT-UD corpora on LINDAT (UPOS
/// under the name `pos`), and SYN2025 (a Czech positional `tag`, and a
/// `pos` that is *not* UPOS).
enum Profiles {
    static func values(_ vs: String...) -> [CorpusProfile.ValueCount] {
        vs.enumerated().map { .init(value: $0.element, count: 1000 - $0.offset) }
    }

    static func attr(_ name: String, _ values: [CorpusProfile.ValueCount]) -> CorpusProfile.Attribute {
        .init(name: name, label: nil, topValues: values)
    }

    static let uposValues = values(
        "NOUN", "PUNCT", "VERB", "PRON", "ADP", "DET", "ADJ", "PROPN", "AUX", "ADV",
        "CCONJ", "PART", "NUM", "SCONJ", "SYM", "INTJ", "X")

    static let featsValues = values("_", "Number=Sing", "VerbForm=Fin", "Person=3", "Number=Plur",
                                    "Mood=Ind", "PronType=Prs", "Degree=Sup")

    static let deprelValues = values("punct", "case", "nsubj", "det", "root", "advmod", "obj",
                                     "amod", "obl", "conj", "acl:relcl", "nsubj:pass")

    static func profile(attributes: [CorpusProfile.Attribute],
                        structures: [CorpusProfile.StructureAttribute] = []) -> CorpusProfile {
        let info = CorpusInfo(
            name: "t", sizeTokens: 1, attributes: attributes.map(\.name),
            structures: Dictionary(grouping: structures, by: { String($0.name.split(separator: ".")[0]) })
                .map { StructureInfo(name: $0.key, attributes: $0.value.map { String($0.name.split(separator: ".")[1]) }) }
                .sorted { $0.name < $1.name })
        var p = CorpusProfile(info: info, attributes: attributes, structureAttributes: structures)
        p.detectRoles()
        return p
    }

    static let genre = CorpusProfile.StructureAttribute(
        name: "doc.genre", label: nil, topValues: values("reviews", "email"), isComplete: true)
    static let docID = CorpusProfile.StructureAttribute(
        name: "doc.id", label: nil,
        topValues: [.init(value: "a-1", count: 1), .init(value: "a-2", count: 1)], isComplete: false)

    static let udEnglish = profile(
        attributes: [attr("word", values("the", ",")), attr("lemma", values("the", "be")),
                     attr("upos", uposValues), attr("xpos", values("NN", "IN", ",")),
                     attr("feats", featsValues), attr("deprel", deprelValues)],
        structures: [docID, genre])

    static let dgtUD = profile(
        attributes: [attr("word", values("a")), attr("lemma", values("a")), attr("pos", uposValues),
                     attr("feats", featsValues), attr("p_lemma", values("a"))])

    static let syn = profile(
        attributes: [attr("word", values("a")), attr("lemma", values("a")),
                     attr("tag", values("Z:-------------", "J^-------------", "RR--6----------",
                                        "VB-S---3P-AAI--", "NNFS4-----A----")),
                     attr("pos", values("N", "Z", "V", "P", "A", "R")),
                     attr("p_tag", values("VB-S---3P-AAI--")),
                     attr("ep_lemma", values("a"))])
}

@Suite struct RoleDetectionTests {
    @Test func udEnglishRoles() {
        let roles = Dictionary(uniqueKeysWithValues: Profiles.udEnglish.attributes.map { ($0.name, $0.role) })
        #expect(roles == ["word": .word, "lemma": .lemma, "upos": .udPOS, "xpos": .other,
                          "feats": .udFeatures, "deprel": .udRelation])
        #expect(Profiles.udEnglish.tagsetFamily == .ud)
    }

    /// Detection goes by values, so DGT-UD's `pos` is UPOS...
    @Test func uposUnderAnotherName() {
        #expect(Profiles.dgtUD.attribute(for: .udPOS)?.name == "pos")
    }

    /// ...and SYN2025's single-letter `pos` isn't.
    @Test func czechPositional() {
        #expect(Profiles.syn.attribute(for: .czechPositionalTag)?.name == "tag")
        #expect(Profiles.syn.attributes.first { $0.name == "pos" }?.role == .other)
        #expect(Profiles.syn.tagsetFamily == .czechPositional)
    }

    /// A few UPOS-looking values don't make an attribute UPOS.
    @Test func sparseUposIsNotEnough() {
        let a = Profiles.attr("t", Profiles.values("NOUN", "VERB", "X"))
        #expect(CorpusProfile.role(of: a) == .other)
    }

    @Test func featureSyntax() {
        #expect(CorpusProfile.isUDFeature("Number=Sing"))
        #expect(CorpusProfile.isUDFeature("Person[psor]=3"))
        #expect(!CorpusProfile.isUDFeature("Number=Sing|Person=3"))
        #expect(!CorpusProfile.isUDFeature("nmod:poss"))
    }

    @Test func structureCategories() {
        #expect(Profiles.genre.isCategorical)
        #expect(!Profiles.docID.isCategorical)
    }
}

@Suite struct QuerySchemaTests {
    private func decoded(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func attributeNamesAreEnumerated() throws {
        let json = QuerySchema.json(attributes: ["word", "lemma", "upos"],
                                    structureAttributes: ["doc.genre"])
        let root = try decoded(json)
        let props = try #require(root["properties"] as? [String: Any])
        let positions = try #require(props["positions"] as? [String: Any])
        let position = try #require(positions["items"] as? [String: Any])
        let conditions = try #require((position["properties"] as? [String: Any])?["conditions"] as? [String: Any])
        let condition = try #require(conditions["items"] as? [String: Any])
        let attribute = try #require((condition["properties"] as? [String: Any])?["attribute"] as? [String: Any])
        #expect(attribute["enum"] as? [String] == ["word", "lemma", "upos"])
        let within = try #require(props["within"] as? [String: Any])
        let item = try #require(within["items"] as? [String: Any])
        let wattr = try #require((item["properties"] as? [String: Any])?["attribute"] as? [String: Any])
        #expect(wattr["enum"] as? [String] == ["doc.genre"])
    }

    /// Generation order is schema order: the query first, the explanation last.
    @Test func propertyOrder() throws {
        let json = QuerySchema.json(attributes: ["word"], structureAttributes: [])
        let p = try #require(json.range(of: #""positions""#)).lowerBound
        let w = try #require(json.range(of: #""within""#)).lowerBound
        let e = try #require(json.range(of: #""explanation""#)).lowerBound
        #expect(p < w && w < e)
    }

    /// No structure attributes: `within` can only be empty (an empty enum
    /// would make the schema unsatisfiable).
    @Test func noStructures() throws {
        let json = QuerySchema.json(attributes: ["word"], structureAttributes: [])
        let props = try #require(try decoded(json)["properties"] as? [String: Any])
        let within = try #require(props["within"] as? [String: Any])
        #expect(within["maxItems"] as? Int == 0)
        #expect(within["items"] == nil)
    }

    @Test func namesAreEscaped() throws {
        let json = QuerySchema.json(attributes: [#"we"ird\name"#, "slovní_tvar"], structureAttributes: [])
        #expect(json.contains(#""we\"ird\\name""#))
        _ = try decoded(json)
    }

    @Test func structureNamesFromInfo() {
        let info = CorpusInfo(name: "t", sizeTokens: 1, attributes: ["word"], structures: [
            StructureInfo(name: "doc", attributes: ["id", "genre"]),
            StructureInfo(name: "s", attributes: []),
        ])
        #expect(QuerySchema.structureAttributeNames(info) == ["doc.id", "doc.genre"])
    }

    /// The examples in the prompt are written the way the model must write.
    @Test func compactJSONRoundTrips() throws {
        let plan = QueryPlan(
            positions: [.init(conditions: [.init(attribute: "word", value: #"a"b"#)], repetition: .optional)],
            within: [.init(attribute: "doc.genre", value: "email")], explanation: "x")
        #expect(plan.compactJSON.hasPrefix(#"{"positions":[{"conditions":[{"attribute":"word","op":"=","value":"a\"b"}],"repeat":"optional"}]"#))
        #expect(try JSONDecoder().decode(QueryPlan.self, from: Data(plan.compactJSON.utf8)) == plan)
    }
}

@Suite struct QueryContextBuilderTests {
    @Test func bundledResourcesLoad() {
        #expect(TagsetGlosses.shared.udPOS.count == 17)
        #expect(ExampleBank.shared.examples.count >= 10)
    }

    /// Every placeholder in the bank is one the builder can fill, or its
    /// example would silently never be used.
    @Test func bankPlaceholdersAreKnown() {
        let known: Set<String> = Set(["word", "lemma", "udPOS", "udFeatures", "udRelation",
                                      "czechPositionalTag", "category", "categoryValue"])
        let everything = Dictionary(uniqueKeysWithValues: known.map { ($0, "x") })
        for example in ExampleBank.shared.examples {
            #expect(example.filled(with: everything) != nil, "\(example.request)")
        }
    }

    @Test func placeholdersTakeTheCorpusNames() {
        let examples = ExampleBank.shared.instantiated(for: Profiles.dgtUD)
        let attributes = Set(examples.flatMap { $0.plan.positions.flatMap { $0.conditions.map(\.attribute) } })
        #expect(attributes.contains("pos"))
        #expect(!attributes.contains("upos"))
        #expect(!attributes.contains { $0.contains("{") })
        // DGT-UD here has no deprel and no structures: those examples drop out.
        #expect(!examples.contains { $0.request.contains("main verb") })
        #expect(!examples.contains { !$0.plan.within.isEmpty })
    }

    @Test func categoryExamplesUseARealValue() {
        let examples = ExampleBank.shared.instantiated(for: Profiles.udEnglish)
        let within = examples.first { !$0.plan.within.isEmpty }
        #expect(within?.plan.within.first == .init(attribute: "doc.genre", value: "reviews"))
        #expect(within?.request.contains("reviews") == true)
    }

    @Test func examplesMatchingTheRequestComeFirst() {
        let examples = ExampleBank.shared.instantiated(for: Profiles.udEnglish)
        let chosen = ExampleBank.select(examples, for: "ordinal numbers in the plural", count: 2)
        #expect(chosen.contains { $0.request == "ordinal numbers" })
    }

    @Test func udValuesAreGlossed() {
        let prompt = QueryContextBuilder.build(profile: Profiles.udEnglish, request: "x")
        #expect(prompt.system.contains("ADP – adposition"))
        #expect(prompt.system.contains("Degree=Sup – superlative"))
        #expect(prompt.system.contains("acl:relcl – relative clause"))
        #expect(prompt.system.contains("doc.genre: reviews; email"))
        #expect(prompt.system.contains("doc.id: free text or identifiers"))
        #expect(prompt.user == "Request: x")
    }

    @Test func czechTagAndParentAttributes() {
        let prompt = QueryContextBuilder.build(profile: Profiles.syn, request: "x")
        #expect(prompt.system.contains("tag: Czech a 15-character positional tag"))
        #expect(prompt.system.contains("p_tag: like tag, but of the token's syntactic parent"))
        #expect(prompt.system.contains("ep_lemma: like lemma, but of the token's effective syntactic parent"))
    }

    /// A tight budget drops detail instead of overflowing the context.
    @Test func budgetShrinksThePrompt() {
        let full = QueryContextBuilder.build(profile: Profiles.udEnglish, request: "x")
        let fullTokens = (full.system.utf8.count + 3) / 4
        let tight = QueryContextBuilder.build(profile: Profiles.udEnglish, request: "x",
                                              budget: fullTokens - 50)
        #expect(tight.system.count < full.system.count)
        #expect(tight.exampleRequests.count < full.exampleRequests.count)
    }
}
