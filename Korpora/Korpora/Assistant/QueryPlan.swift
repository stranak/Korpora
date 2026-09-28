import Foundation

/// What the query assistant's model fills in instead of writing CQL itself
/// (docs/nl-query-assistant.md, "Structured output, not free text"): a
/// sequence of token positions plus optional structure restrictions.
/// `CQLSerializer` turns it into a query, so a generated query can't be
/// syntactically invalid - the model only ever chooses attributes, operators
/// and values, each of which the generation schema constrains.
///
/// Deliberately a subset of CQL - no `meet`/`union`/`containing`, no
/// structure tags as positions. The result lands in the query field for
/// review, so anything beyond this subset is still a hand edit away.
///
/// Plain `Codable`: the JSON Schema that constrains generation is built
/// *from* this type's shape at runtime, and the model's output is decoded
/// back *into* it, so everything downstream (serializing, validating,
/// testing) needs no model at all.
struct QueryPlan: Codable, Equatable {
    var positions: [Position]
    /// Restrictions on the enclosing structure, e.g. `doc.genre = email`.
    var within: [StructureCondition]
    /// One sentence for the user, shown next to the generated query.
    var explanation: String

    struct Position: Codable, Equatable {
        /// All must hold for the token (CQL `&`). Empty means any token, `[]`.
        var conditions: [Condition]
        var repetition: Repeat

        init(conditions: [Condition], repetition: Repeat = .once) {
            self.conditions = conditions
            self.repetition = repetition
        }

        /// `repeat` on the wire (that's the word a model reads best), but a
        /// Swift keyword, hence the different property name.
        enum CodingKeys: String, CodingKey {
            case conditions
            case repetition = "repeat"
        }
    }

    struct Condition: Codable, Equatable {
        var attribute: String
        var op: Operator
        /// A literal or a manatee regex - CQL `=` matches regexes against
        /// the whole value, so `un.*` means "starts with un".
        var value: String
    }

    struct StructureCondition: Codable, Equatable {
        /// Dotted `structure.attribute`, the same spelling
        /// `CQLCompletionProvider.attributeNames` offers, e.g. `doc.genre`.
        var attribute: String
        var value: String
    }

    enum Operator: String, Codable, CaseIterable {
        case equals = "="
        case notEquals = "!="
    }

    /// CQL's repetition suffixes, spelled out so a model can't confuse them.
    enum Repeat: String, Codable, CaseIterable {
        case once
        case optional = "optional"          // ?
        case zeroOrMore = "zero-or-more"    // *
        case oneOrMore = "one-or-more"      // +
    }
}
