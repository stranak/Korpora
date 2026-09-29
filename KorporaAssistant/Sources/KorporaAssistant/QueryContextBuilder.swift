import Foundation

/// The prompt the assistant's model sees: the rules of a `QueryPlan`, this
/// corpus's attributes with their real (and, for known tagsets, explained)
/// values, and a few worked examples picked for the request
/// (docs/nl-query-assistant.md, "Corpus facts in the prompt").
public struct QueryPrompt: Sendable, Equatable {
    public var system: String
    public var user: String
    /// The requests of the examples included, for logging and tests.
    public var exampleRequests: [String]
}

public enum QueryContextBuilder {
    /// How much of each part goes in. `levels` runs from most to least
    /// detail; `build` takes the first that fits the budget, so a small
    /// context window loses the long tail of feature values and examples
    /// before anything essential.
    struct Detail: Equatable {
        var examples: Int
        var udFeatures: Int
        var udRelations: Int
        /// Values listed for an attribute with no known tagset; 0 lists only
        /// its name and description.
        var otherValues: Int
        var structureValues: Int
    }

    static let levels: [Detail] = [
        Detail(examples: 5, udFeatures: 80, udRelations: 50, otherValues: 30, structureValues: 30),
        Detail(examples: 4, udFeatures: 50, udRelations: 35, otherValues: 15, structureValues: 20),
        Detail(examples: 3, udFeatures: 30, udRelations: 25, otherValues: 8, structureValues: 12),
        Detail(examples: 2, udFeatures: 20, udRelations: 15, otherValues: 0, structureValues: 8),
    ]

    /// - Parameters:
    ///   - budget: tokens the prompt may take - the model's context minus
    ///     what generation needs.
    ///   - countTokens: the model's own tokenizer; the default is a rough
    ///     4-characters-per-token estimate for when none is at hand.
    /// Knobs for comparing prompt variants in the benchmark
    /// (`korpora-assistant prompts --level N --no-retrieval`); the app
    /// uses the defaults.
    public struct Options: Sendable {
        /// Start at this entry of `levels` instead of the most detailed.
        public var firstLevel = 0
        /// Pick examples by overlap with the request; off, the bank's
        /// first examples are used for every request.
        public var retrieveExamples = true

        public init(firstLevel: Int = 0, retrieveExamples: Bool = true) {
            self.firstLevel = firstLevel
            self.retrieveExamples = retrieveExamples
        }
    }

    public static func build(
        profile: CorpusProfile, request: String, budget: Int = .max,
        countTokens: (String) -> Int = { ($0.utf8.count + 3) / 4 },
        options: Options = .init()
    ) -> QueryPrompt {
        let examples = ExampleBank.shared.instantiated(for: profile)
        var prompt = QueryPrompt(system: "", user: "", exampleRequests: [])
        for detail in levels.dropFirst(min(options.firstLevel, levels.count - 1)) {
            prompt = build(profile: profile, request: request, examples: examples, detail: detail,
                           retrieve: options.retrieveExamples)
            if countTokens(prompt.system) + countTokens(prompt.user) <= budget { break }
        }
        return prompt
    }

    static func build(
        profile: CorpusProfile, request: String, examples: [ExampleBank.Example], detail: Detail,
        retrieve: Bool = true
    ) -> QueryPrompt {
        let chosen = retrieve
            ? ExampleBank.select(examples, for: request, count: detail.examples)
            : Array(examples.prefix(detail.examples))
        var system = rules + "\n\n" + corpusFacts(profile, detail: detail)
        if !chosen.isEmpty {
            system += "\n\nExamples:\n" + chosen.map {
                "Request: \($0.request)\n\($0.plan.compactJSON)"
            }.joined(separator: "\n\n")
        }
        return QueryPrompt(system: system, user: "Request: \(request)",
                           exampleRequests: chosen.map(\.request))
    }

    static let rules = """
        You turn a linguist's request into a corpus search pattern. Output only the QueryPlan object.

        How a QueryPlan works:
        - "positions" is a sequence of consecutive tokens (words). Each position lists conditions that must ALL hold for that token.
        - Each position is ONE token: all conditions about the same word go into the SAME position ("plural proper nouns" is one position with two conditions, not two positions).
        - A condition compares one token attribute with a value. Values are exact strings or regular expressions over the whole value (".*" = anything, "a|b" = either, "un.*" = starts with "un"). Matching is case-sensitive.
        - A position with no conditions matches any single token.
        - "repeat": "once" (normal), "optional" (0 or 1 tokens), "zero-or-more", "one-or-more". Use "optional" or "zero-or-more" on an empty position to allow gaps between words.
        - "within" restricts the whole match to structures (e.g. documents) with a given attribute value. Leave it empty unless the request names one.
        - Use lemma for "any form of" a word (lemma "go" matches go, went, gone). Use word for an exact word form.
        """

    // MARK: Corpus facts

    static func corpusFacts(_ profile: CorpusProfile, detail: Detail) -> String {
        let names = Set(profile.attributes.map(\.name))
        var lines = ["This corpus has these token attributes:"]
        for attribute in profile.attributes {
            lines.append("- " + describe(attribute, detail: detail, allNames: names))
        }
        let structures = profile.structureAttributes
        if !structures.isEmpty {
            lines.append("")
            lines.append("Structure attributes, for \"within\":")
            for s in structures {
                lines.append("- " + describe(s, detail: detail))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ a: CorpusProfile.Attribute, detail: Detail, allNames: Set<String>) -> String {
        let glosses = TagsetGlosses.shared
        func listed(_ limit: Int, _ gloss: [String: String]? = nil,
                    fallback: ((String) -> String?)? = nil) -> String {
            a.topValues.lazy.map(\.value).filter { !["_", ""].contains($0) }.prefix(limit).map { v in
                if let g = gloss?[v] ?? fallback?(v) { return "\(v) – \(g)" }
                return v
            }.joined(separator: "; ")
        }
        let label = a.label.map { " (\($0))" } ?? ""
        if let base = parentBase(a.name, allNames: allNames) {
            // SYN2025 and the DGT-UD corpora both mirror attributes for the
            // syntactic parent (`p_lemma`) and, in SYN, the effective parent
            // (`ep_lemma`). Checked before the role: `p_tag` holds tags too,
            // but listing them again would only repeat `tag`. A heuristic
            // on the name, so it gives way to a registry LABEL.
            if a.label == nil {
                let whose = a.name.hasPrefix("ep_") ? "effective syntactic parent" : "syntactic parent"
                return "\(a.name): like \(base), but of the token's \(whose)"
            }
            return "\(a.name)\(label)"
        }
        // Values are separated by "; " because a value may itself be a
        // comma (Penn's `,` tag); a gloss follows its value after " – ".
        switch a.role {
        case .word:
            return "\(a.name)\(label): the word form as written"
        case .lemma:
            return "\(a.name)\(label): the dictionary form; use it for \"any form of\""
        case .udPOS:
            return "\(a.name)\(label): part of speech (Universal Dependencies): "
                + listed(.max, glosses.udPOS)
        case .udFeatures:
            return "\(a.name)\(label): morphological features, one Feature=Value per condition: "
                + listed(detail.udFeatures, glosses.udFeatures)
        case .udRelation:
            return "\(a.name)\(label): syntactic relation to the parent word (Universal Dependencies): "
                + listed(detail.udRelations, glosses.udRelation) { value in
                    // An unlisted subtype (`obl:arg`) is still its base relation.
                    value.split(separator: ":").first.flatMap { glosses.udRelation[String($0)] }
                        .map { "\($0), subtype" }
                }
        case .czechPositionalTag:
            return "\(a.name)\(label): Czech " + glosses.czechPositionalTag.joined(separator: "\n    ")
        case .other:
            guard detail.otherValues > 0 else { return "\(a.name)\(label)" }
            return "\(a.name)\(label), values such as: " + listed(detail.otherValues)
        }
    }

    /// `p_lemma` → `lemma`, when `lemma` exists.
    static func parentBase(_ name: String, allNames: Set<String>) -> String? {
        for prefix in ["ep_", "p_"] where name.hasPrefix(prefix) {
            let base = String(name.dropFirst(prefix.count))
            if allNames.contains(base) { return base }
        }
        return nil
    }

    static func describe(_ s: CorpusProfile.StructureAttribute, detail: Detail) -> String {
        let label = s.label.map { " (\($0))" } ?? ""
        guard s.isCategorical else {
            return "\(s.name)\(label): free text or identifiers"
        }
        let values = s.topValues.prefix(detail.structureValues).map(\.value)
        let more = s.topValues.count > values.count ? "; ..." : ""
        return "\(s.name)\(label): " + values.joined(separator: "; ") + more
    }
}

// MARK: - Glosses

struct TagsetGlosses: Decodable {
    var udPOS: [String: String]
    var udRelation: [String: String]
    var udFeatures: [String: String]
    var czechPositionalTag: [String]

    static let shared: TagsetGlosses = load("TagsetGlosses")
}

/// A bundled JSON resource. The files ship with the package, so failing to
/// read one is a build error in disguise, not a runtime condition.
func load<T: Decodable>(_ name: String) -> T {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        fatalError("\(name).json missing from the KorporaAssistant bundle")
    }
    do {
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    } catch {
        fatalError("\(name).json doesn't decode: \(error)")
    }
}

// MARK: - Examples

struct ExampleBank: Decodable {
    var examples: [Example]

    struct Example: Decodable, Equatable {
        var request: String
        var plan: QueryPlan
    }

    static let shared: ExampleBank = load("ExampleBank")

    /// The examples this corpus can express, placeholders filled in:
    /// `{udPOS}` becomes `upos` in UD English EWT and `pos` in DGT-UD.
    func instantiated(for profile: CorpusProfile) -> [Example] {
        var names: [String: String] = [:]
        for attribute in profile.attributes where names[attribute.role.rawValue] == nil {
            names[attribute.role.rawValue] = attribute.name
        }
        if let category = Self.category(in: profile), let value = category.topValues.first?.value {
            names["category"] = category.name
            names["categoryValue"] = value
        }
        return examples.compactMap { $0.filled(with: names) }
    }

    /// The structure attribute examples use for `within`: a categorical one,
    /// preferring the usual names for a text category.
    static func category(in profile: CorpusProfile) -> CorpusProfile.StructureAttribute? {
        let categorical = profile.structureAttributes.filter {
            $0.isCategorical && $0.topValues.count >= 2
        }
        let preferred = ["genre", "text_type", "texttype", "type", "category", "medium"]
        for name in preferred {
            if let match = categorical.first(where: { $0.name.hasSuffix(".\(name)") }) { return match }
        }
        return categorical.first
    }

    /// The `count` examples sharing the most words with the request, ties
    /// in bank order - which puts the basic patterns first when nothing
    /// matches.
    static func select(_ examples: [Example], for request: String, count: Int) -> [Example] {
        let wanted = keywords(request)
        let scores: [Int] = examples.map { keywords($0.request).intersection(wanted).count }
        let ranked: [Int] = examples.indices.sorted { a, b in
            scores[a] != scores[b] ? scores[a] > scores[b] : a < b
        }
        return ranked.prefix(count).sorted().map { examples[$0] }
    }

    private static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "by", "and", "or", "to", "that", "which",
        "is", "are", "with", "any", "word", "words", "form", "followed",
    ]

    static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map { word -> String in
            // Crude singular: enough for "nouns"/"noun", "verbs"/"verb".
            word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : String(word)
        }.filter { !stopwords.contains($0) })
    }
}

extension ExampleBank.Example {
    /// Nil when the example needs a placeholder this corpus can't fill.
    func filled(with names: [String: String]) -> Self? {
        var missing = false
        func fill(_ text: String) -> String {
            var out = text
            for match in text.matches(of: #/\{([A-Za-z]+)\}/#) {
                let key = String(match.1)
                guard let name = names[key] else { missing = true; continue }
                out = out.replacingOccurrences(of: "{\(key)}", with: name)
            }
            return out
        }
        var plan = plan
        for p in plan.positions.indices {
            for c in plan.positions[p].conditions.indices {
                plan.positions[p].conditions[c].attribute = fill(plan.positions[p].conditions[c].attribute)
                plan.positions[p].conditions[c].value = fill(plan.positions[p].conditions[c].value)
            }
        }
        for w in plan.within.indices {
            plan.within[w].attribute = fill(plan.within[w].attribute)
            plan.within[w].value = fill(plan.within[w].value)
        }
        plan.explanation = fill(plan.explanation)
        let request = fill(request)
        return missing ? nil : Self(request: request, plan: plan)
    }
}
