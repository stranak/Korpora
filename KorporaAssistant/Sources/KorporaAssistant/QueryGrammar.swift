import Foundation

/// The QueryPlan's JSON as an EBNF grammar for XGrammar, which
/// MLXGuidedGeneration compiles with `GrammarConstraint(grammar:)`.
///
/// It accepts the same language as `QuerySchema`, but with **no free
/// whitespace**. The schema path can't express that: mlx-swift-lm's
/// XGrammar bridge compiles JSON Schemas with XGrammar's defaults
/// (`any_whitespace=true`), and with whitespace allowed Qwen3-4B emitted a
/// run of newlines inside the first key and then produced a wrong query
/// (docs/nl-query-assistant.md, "Phase 3"). Writing the grammar ourselves
/// also allows escaped `\\` and `\"` inside values, which XGrammar's
/// `maxLength` strings exclude - so a regex like `\?` can be generated.
public enum QueryGrammar {
    /// - Parameter spaced: `", "` / `": "` between JSON items, the way
    ///   XGrammar's own compact output and phase 0's benchmark runs spell
    ///   it; otherwise `","` / `":"`, matching `QueryPlan.compactJSON` and
    ///   the examples in the prompt.
    public static func ebnf(attributes: [String], structureAttributes: [String], spaced: Bool = false) -> String {
        let comma = spaced ? ", " : ","
        let colon = spaced ? ": " : ":"
        func key(_ name: String) -> String { lit("\"\(name)\"\(colon)") }
        func alternatives(_ names: [String]) -> String {
            names.map { lit(jsonQuoted($0)) }.joined(separator: " | ")
        }
        func list(_ item: String, max: Int) -> String {
            "\"[]\" | \"[\" \(item) (\(lit(comma)) \(item)){0,\(max - 1)} \"]\""
        }
        var rules = [
            "root ::= \"{\" \(key("positions")) \"[\" position (\(lit(comma)) position){0,\(QuerySchema.maxPositions - 1)} \"]\" "
                + "\(lit(comma)) \(key("within")) within \(lit(comma)) \(key("explanation")) explanation \"}\"",
            "position ::= \"{\" \(key("conditions")) conditions \(lit(comma)) \(key("repeat")) repeat \"}\"",
            "conditions ::= " + list("condition", max: QuerySchema.maxConditions),
            "condition ::= \"{\" \(key("attribute")) attribute \(lit(comma)) \(key("op")) op \(lit(comma)) \(key("value")) value \"}\"",
            "attribute ::= " + alternatives(attributes),
            "op ::= " + alternatives(QueryPlan.Operator.allCases.map(\.rawValue)),
            "repeat ::= " + alternatives(QueryPlan.Repeat.allCases.map(\.rawValue)),
        ]
        if structureAttributes.isEmpty {
            rules.append("within ::= \"[]\"")
        } else {
            rules.append("within ::= " + list("structurecondition", max: QuerySchema.maxWithin))
            rules.append("structurecondition ::= \"{\" \(key("attribute")) structureattribute \(lit(comma)) \(key("value")) value \"}\"")
            rules.append("structureattribute ::= " + alternatives(structureAttributes))
        }
        rules += [
            "value ::= \"\\\"\" char{0,\(QuerySchema.maxValueLength)} \"\\\"\"",
            "explanation ::= \"\\\"\" char{0,\(QuerySchema.maxExplanationLength)} \"\\\"\"",
            // Any character JSON allows raw, or an escaped quote/backslash.
            #"char ::= [^\0-\x1f"\\] | "\\" ["\\]"#,
        ]
        return rules.joined(separator: "\n")
    }

    /// A JSON string literal for `s` (the text the model must produce).
    static func jsonQuoted(_ s: String) -> String {
        OrderedJSON.string(s).serialized()
    }

    /// An EBNF string literal matching `text` exactly.
    static func lit(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
