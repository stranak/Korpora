import Foundation
import ManateeKit

/// The JSON Schema that constrains the assistant's model to a `QueryPlan`
/// for one particular corpus (docs/nl-query-assistant.md, "Structured
/// output, not free text").
///
/// Attribute and structure-attribute names are `enum`s of the corpus's
/// real ones, so the model can't name an attribute that doesn't exist;
/// values stay free strings (a positional tagset has thousands). Property
/// order is the generation order - XGrammar emits properties in the order
/// the schema lists them - so `positions` comes first and the one-line
/// `explanation` last, after the model has committed to a query.
public enum QuerySchema {
    /// Caps that keep a small model from rambling: a longer query than this
    /// is rare in practice and still a hand edit away.
    static let maxPositions = 8
    static let maxConditions = 4
    static let maxWithin = 3
    static let maxValueLength = 80
    static let maxExplanationLength = 200

    public static func json(for info: CorpusInfo) -> String {
        json(attributes: info.attributes,
             structureAttributes: structureAttributeNames(info))
    }

    /// `doc.genre`-style names, in registry order - the same spelling
    /// `QueryPlan.StructureCondition.attribute` and `CQLSerializer` use.
    public static func structureAttributeNames(_ info: CorpusInfo) -> [String] {
        info.structures.flatMap { s in s.attributes.map { "\(s.name).\($0)" } }
    }

    public static func json(attributes: [String], structureAttributes: [String]) -> String {
        schema(attributes: attributes, structureAttributes: structureAttributes).serialized()
    }

    private static func schema(attributes: [String], structureAttributes: [String]) -> OrderedJSON {
        let condition: OrderedJSON = object([
            ("attribute", .object([("type", "string"), ("enum", .array(attributes.map { .string($0) }))])),
            ("op", .object([("type", "string"),
                            ("enum", .array(QueryPlan.Operator.allCases.map { .string($0.rawValue) }))])),
            ("value", .object([("type", "string"), ("maxLength", .int(maxValueLength))])),
        ])
        let position: OrderedJSON = object([
            ("conditions", .object([("type", "array"), ("maxItems", .int(maxConditions)),
                                    ("items", condition)])),
            ("repeat", .object([("type", "string"),
                                ("enum", .array(QueryPlan.Repeat.allCases.map { .string($0.rawValue) }))])),
        ])
        // A corpus without structure attributes can't have `within`
        // conditions; an empty `enum` would make the item schema
        // unsatisfiable, so the array is pinned to empty instead.
        let within: OrderedJSON
        if structureAttributes.isEmpty {
            within = .object([("type", "array"), ("maxItems", .int(0))])
        } else {
            within = .object([
                ("type", "array"), ("maxItems", .int(maxWithin)),
                ("items", object([
                    ("attribute", .object([("type", "string"),
                                           ("enum", .array(structureAttributes.map { .string($0) }))])),
                    ("value", .object([("type", "string"), ("maxLength", .int(maxValueLength))])),
                ])),
            ])
        }
        return object([
            ("positions", .object([("type", "array"), ("minItems", .int(1)),
                                   ("maxItems", .int(maxPositions)), ("items", position)])),
            ("within", within),
            ("explanation", .object([("type", "string"), ("maxLength", .int(maxExplanationLength))])),
        ])
    }

    /// A closed object schema: every property required, nothing else allowed.
    private static func object(_ properties: [(String, OrderedJSON)]) -> OrderedJSON {
        .object([
            ("type", "object"),
            ("properties", .object(properties)),
            ("required", .array(properties.map { .string($0.0) })),
            ("additionalProperties", .bool(false)),
        ])
    }
}

/// Just enough JSON to write a schema with its keys in a chosen order,
/// which `JSONSerialization`/`JSONEncoder` don't offer (`.sortedKeys` is
/// the only ordering they guarantee).
indirect enum OrderedJSON: ExpressibleByStringLiteral {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    init(stringLiteral value: String) { self = .string(value) }

    func serialized() -> String {
        switch self {
        case .string(let s): return Self.quoted(s)
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .array(let items): return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let members):
            return "{" + members.map { Self.quoted($0.0) + ":" + $0.1.serialized() }
                .joined(separator: ",") + "}"
        }
    }

    /// A JSON string literal: `"` and `\` escaped, control characters as
    /// `\uXXXX` (JSON forbids them raw). Everything else - including
    /// non-ASCII, which attribute names in a Czech registry may contain -
    /// passes through as UTF-8.
    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension QueryPlan {
    /// The plan as the model writes it: compact, keys in schema order. Used
    /// for the worked examples in the prompt, so they look exactly like
    /// the output the model is constrained to.
    public var compactJSON: String {
        func condition(_ c: Condition) -> OrderedJSON {
            .object([("attribute", .string(c.attribute)), ("op", .string(c.op.rawValue)),
                     ("value", .string(c.value))])
        }
        return OrderedJSON.object([
            ("positions", .array(positions.map { p in
                .object([("conditions", .array(p.conditions.map(condition))),
                         ("repeat", .string(p.repetition.rawValue))])
            })),
            ("within", .array(within.map { w in
                .object([("attribute", .string(w.attribute)), ("value", .string(w.value))])
            })),
            ("explanation", .string(explanation)),
        ]).serialized()
    }
}
