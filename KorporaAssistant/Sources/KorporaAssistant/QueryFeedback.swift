import Foundation

/// What the retry prompt tells the model when its first query is wrong
/// (docs/nl-query-assistant.md, "Validation loop"): the engine's own error,
/// values that don't occur in the corpus (with real ones that look like
/// them), or a query that finds nothing. The checks against the corpus are
/// the caller's; this only decides what's worth a retry and phrases it.
public enum QueryFeedback {
    public struct MissingValue: Sendable, Equatable {
        public var attribute: String
        public var value: String
        public var similar: [String]
        /// Other attributes that do have this exact value - the model put
        /// a relation into `feats`, or a feature into `upos`.
        public var foundIn: [String]

        public init(attribute: String, value: String, similar: [String], foundIn: [String] = []) {
            self.attribute = attribute
            self.value = value
            self.similar = similar
            self.foundIn = foundIn
        }
    }

    /// Nil when there's nothing to fix. Checked in order of how certain
    /// the diagnosis is: an engine error is definite, a missing value
    /// nearly so, zero hits only suggestive.
    public static func message(engineError: String?, missing: [MissingValue], hits: Int?) -> String? {
        if let engineError {
            return "The corpus engine rejected the query: \(engineError)"
        }
        if !missing.isEmpty {
            return missing.map { m in
                var text = "No token has \(m.attribute)=\"\(m.value)\"."
                if !m.foundIn.isEmpty {
                    text += " \"\(m.value)\" is a value of \(m.foundIn.joined(separator: " and ")), not \(m.attribute)."
                } else if !m.similar.isEmpty {
                    text += " Existing values like it: \(m.similar.joined(separator: ", "))."
                }
                return text
            }.joined(separator: " ")
        }
        if hits == 0 {
            return "The query finds nothing in this corpus."
        }
        return nil
    }

    /// Plain values the model asserted with `=` - the only ones whose
    /// existence can be checked (a regex or a `!=` can't be "missing").
    public static func literalConditions(_ plan: QueryPlan) -> [QueryPlan.Condition] {
        plan.positions.flatMap(\.conditions).filter { $0.op == .equals && !QueryRepair.isRegex($0.value) }
    }

    /// Up to `limit` known values resembling `value`: the same UD feature
    /// (`PronType=Poss` → `PronType=*`), else the same first three letters,
    /// ignoring case.
    public static func similar(to value: String, in known: [String], limit: Int = 8) -> [String] {
        let key: String
        if let eq = value.firstIndex(of: "=") {
            key = String(value[...eq]).lowercased()
        } else {
            key = String(value.prefix(3)).lowercased()
        }
        guard !key.isEmpty else { return [] }
        return Array(known.filter { $0.lowercased().hasPrefix(key) && $0 != value }.prefix(limit))
    }
}
