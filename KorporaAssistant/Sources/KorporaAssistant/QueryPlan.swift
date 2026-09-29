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
public struct QueryPlan: Codable, Equatable, Sendable {
    public var positions: [Position]
    /// Restrictions on the enclosing structure, e.g. `doc.genre = email`.
    public var within: [StructureCondition]
    /// One sentence for the user, shown next to the generated query.
    public var explanation: String

    public init(positions: [Position], within: [StructureCondition] = [], explanation: String = "") {
        self.positions = positions
        self.within = within
        self.explanation = explanation
    }

    public struct Position: Codable, Equatable, Sendable {
        /// All must hold for the token (CQL `&`). Empty means any token, `[]`.
        public var conditions: [Condition]
        public var repetition: Repeat

        public init(conditions: [Condition], repetition: Repeat = .once) {
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

    public struct Condition: Codable, Equatable, Sendable {
        public var attribute: String
        public var op: Operator
        /// A literal or a manatee regex - CQL `=` matches regexes against
        /// the whole value, so `un.*` means "starts with un".
        public var value: String

        public init(attribute: String, op: Operator = .equals, value: String) {
            self.attribute = attribute
            self.op = op
            self.value = value
        }
    }

    public struct StructureCondition: Codable, Equatable, Sendable {
        /// Dotted `structure.attribute`, the same spelling
        /// `CQLCompletionProvider.attributeNames` offers, e.g. `doc.genre`.
        public var attribute: String
        public var value: String

        public init(attribute: String, value: String) {
            self.attribute = attribute
            self.value = value
        }
    }

    public enum Operator: String, Codable, CaseIterable, Sendable {
        case equals = "="
        case notEquals = "!="
    }

    /// CQL's repetition suffixes, spelled out so a model can't confuse them.
    public enum Repeat: String, Codable, CaseIterable, Sendable {
        case once
        case optional = "optional"          // ?
        case zeroOrMore = "zero-or-more"    // *
        case oneOrMore = "one-or-more"      // +
    }
}
