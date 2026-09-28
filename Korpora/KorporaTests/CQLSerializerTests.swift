import Foundation
import Testing
@testable import Korpora

@Suite struct CQLSerializerTests {
    private typealias P = QueryPlan

    private func plan(_ positions: [P.Position], within: [P.StructureCondition] = []) -> P {
        P(positions: positions, within: within, explanation: "")
    }

    private func cond(_ attribute: String, _ value: String, _ op: P.Operator = .equals) -> P.Condition {
        P.Condition(attribute: attribute, op: op, value: value)
    }

    @Test func singleToken() {
        #expect(CQLSerializer.cql(for: plan([.init(conditions: [cond("upos", "NOUN")])]))
            == #"[upos="NOUN"]"#)
    }

    @Test func sequenceAndConjunction() {
        let p = plan([
            .init(conditions: [cond("upos", "ADJ")]),
            .init(conditions: [cond("upos", "NOUN"), cond("feats", "Number=Plur")]),
        ])
        #expect(CQLSerializer.cql(for: p) == #"[upos="ADJ"][upos="NOUN" & feats="Number=Plur"]"#)
    }

    @Test func negationAndAnyToken() {
        let p = plan([
            .init(conditions: [cond("lemma", "go"), cond("word", "going", .notEquals)]),
            .init(conditions: []),
        ])
        #expect(CQLSerializer.cql(for: p) == #"[lemma="go" & word!="going"][]"#)
    }

    @Test func repetitionSuffixes() {
        let p = plan([
            .init(conditions: [], repetition: .optional),
            .init(conditions: [], repetition: .zeroOrMore),
            .init(conditions: [], repetition: .oneOrMore),
            .init(conditions: [], repetition: .once),
        ])
        #expect(CQLSerializer.cql(for: p) == "[]?[]*[]+[]")
    }

    /// Conditions on the same structure share one `within`, ANDed; another
    /// structure gets its own.
    @Test func withinGroupsByStructure() {
        let p = plan(
            [.init(conditions: [cond("upos", "VERB")])],
            within: [
                .init(attribute: "doc.genre", value: "email"),
                .init(attribute: "s.id", value: "x"),
                .init(attribute: "doc.split", value: "dev"),
            ])
        #expect(CQLSerializer.cql(for: p)
            == #"[upos="VERB"] within <doc genre="email" & split="dev"/> within <s id="x"/>"#)
    }

    /// The model supplies values; the serializer owns quoting. A quote in a
    /// value must not end the string, and a regex backslash must survive
    /// manatee's unescaping (`\\` → `\`).
    @Test func valuesAreEscaped() {
        let p = plan([
            .init(conditions: [cond("word", #"say "hi""#)]),
            .init(conditions: [cond("word", #"\."#)]),
        ])
        #expect(CQLSerializer.cql(for: p) == #"[word="say \"hi\""][word="\\."]"#)
    }

    /// Regex metacharacters pass through untouched - they're the point.
    @Test func regexValuesPassThrough() {
        let p = plan([.init(conditions: [cond("word", "un.*|non.*")])])
        #expect(CQLSerializer.cql(for: p) == #"[word="un.*|non.*"]"#)
    }

    /// The model's output is JSON; the enum spellings are the wire format.
    @Test func decodesTheModelsJSON() throws {
        let json = #"""
        {"positions":[{"conditions":[{"attribute":"upos","op":"=","value":"ADJ"}],"repeat":"once"},
                      {"conditions":[],"repeat":"zero-or-more"}],
         "within":[{"attribute":"doc.genre","value":"reviews"}],
         "explanation":"x"}
        """#
        let decoded = try JSONDecoder().decode(QueryPlan.self, from: Data(json.utf8))
        #expect(CQLSerializer.cql(for: decoded) == #"[upos="ADJ"][]* within <doc genre="reviews"/>"#)
    }
}
