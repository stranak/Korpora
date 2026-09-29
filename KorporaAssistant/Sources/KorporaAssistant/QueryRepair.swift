import Foundation

/// Deterministic fixes to a generated plan, before it's validated
/// (docs/nl-query-assistant.md, "Validation loop"). A small model often
/// gets a value almost right - `Degree=cmp` for `Degree=Cmp`, `weblogs`
/// for the genre `weblog` - and such a query runs fine and finds nothing.
/// Where the intended value is unambiguous among the corpus's own values,
/// it's swapped in; anything else is left for the engine check and the
/// retry prompt.
public enum QueryRepair {
    public struct Change: Sendable, Equatable {
        public var attribute: String
        public var from: String
        public var to: String
    }

    public static func repair(_ plan: QueryPlan, profile: CorpusProfile) -> (QueryPlan, [Change]) {
        var plan = plan
        var changes: [Change] = []
        let tokenValues = Dictionary(uniqueKeysWithValues: profile.attributes.map {
            ($0.name, $0.topValues.map(\.value))
        })
        // Only attributes whose values were sampled completely (a tagset, a
        // genre list) are safe to repair against: for word or lemma, a
        // value missing from the top-N sample may well exist.
        let complete = Set(profile.attributes.filter { $0.topValues.count < CorpusProfile.valueSampleSize }
            .map(\.name))
        for p in plan.positions.indices {
            for c in plan.positions[p].conditions.indices {
                let condition = plan.positions[p].conditions[c]
                guard complete.contains(condition.attribute),
                      let known = tokenValues[condition.attribute],
                      let fixed = match(condition.value, in: known, plurals: false)
                else { continue }
                plan.positions[p].conditions[c].value = fixed
                changes.append(Change(attribute: condition.attribute, from: condition.value, to: fixed))
            }
        }
        let structureValues = Dictionary(uniqueKeysWithValues: profile.structureAttributes
            .filter(\.isComplete).map { ($0.name, $0.topValues.map(\.value)) })
        for w in plan.within.indices {
            let condition = plan.within[w]
            guard let known = structureValues[condition.attribute],
                  let fixed = match(condition.value, in: known, plurals: true)
            else { continue }
            plan.within[w].value = fixed
            changes.append(Change(attribute: condition.attribute, from: condition.value, to: fixed))
        }
        return (plan, changes)
    }

    /// The one known value `value` was meant to be, or nil when it's
    /// already right, a regex, or ambiguous.
    static func match(_ value: String, in known: [String], plurals: Bool) -> String? {
        guard !known.contains(value), !isRegex(value) else { return nil }
        func unique(_ candidates: [String]) -> String? {
            candidates.count == 1 ? candidates[0] : nil
        }
        let lower = value.lowercased()
        if let hit = unique(known.filter { $0.lowercased() == lower }) { return hit }
        guard plurals else { return nil }
        let singular = lower.hasSuffix("s") ? String(lower.dropLast()) : lower
        return unique(known.filter {
            let k = $0.lowercased()
            return k == singular || k == lower + "s" || (k.hasSuffix("s") && String(k.dropLast()) == singular)
        })
    }

    /// Contains a metacharacter manatee's regex syntax gives meaning to.
    static func isRegex(_ value: String) -> Bool {
        value.contains { ".*+?|[](){}\\^$".contains($0) }
    }
}
