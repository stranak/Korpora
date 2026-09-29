import Foundation

/// Turns a `QueryPlan` into CQL. Pure and total: every plan serializes, and
/// quoting is done here rather than trusted to the model, so a value like
/// `say "hi"` can't break out of its string.
public enum CQLSerializer {
    public static func cql(for plan: QueryPlan) -> String {
        var query = plan.positions.map(position).joined()
        // One `within` per structure, its conditions ANDed: CQL takes
        // `within <doc genre="email" & split="dev"/>`, not two `<doc>`s.
        var order: [String] = []
        var byStructure: [String: [String]] = [:]
        for condition in plan.within {
            let (structure, attribute) = split(condition.attribute)
            if byStructure[structure] == nil { order.append(structure) }
            byStructure[structure, default: []].append("\(attribute)=\(quoted(condition.value))")
        }
        for structure in order {
            query += " within <\(structure) \(byStructure[structure]!.joined(separator: " & "))/>"
        }
        return query
    }

    private static func position(_ position: QueryPlan.Position) -> String {
        let conditions = position.conditions
            .map { "\($0.attribute)\($0.op.rawValue)\(quoted($0.value))" }
            .joined(separator: " & ")
        return "[\(conditions)]" + suffix(position.repetition)
    }

    private static func suffix(_ repetition: QueryPlan.Repeat) -> String {
        switch repetition {
        case .once: return ""
        case .optional: return "?"
        case .zeroOrMore: return "*"
        case .oneOrMore: return "+"
        }
    }

    /// `doc.genre` → (`doc`, `genre`). A name without a dot can't be a
    /// structure attribute; it's kept whole as the structure so the engine's
    /// own error names it, rather than silently dropping the condition.
    private static func split(_ dotted: String) -> (String, String) {
        guard let dot = dotted.firstIndex(of: ".") else { return (dotted, "") }
        return (String(dotted[..<dot]), String(dotted[dotted.index(after: dot)...]))
    }

    /// A CQL string literal. Only `"` and `\` need escaping; everything
    /// else, regex metacharacters included, is meant to reach the engine.
    /// Matches manatee's lexer exactly (`unescapeString` in
    /// manatee-open/query/cqpeval.y turns `\\` into `\` and `\"` into `"`,
    /// nothing else), so a regex value `\.` arrives as `\.` - a literal dot.
    public static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
