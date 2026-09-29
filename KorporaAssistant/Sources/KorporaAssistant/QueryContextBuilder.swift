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
        /// UD values listed in the gloss table's order and only if glossed
        /// (off, the default: every value present, by frequency). Neutral
        /// for Qwen3-4B, clearly worse for Qwen3-8B (34 vs 42 of 60 on the
        /// dev split), so it's kept only for comparison.
        public var curatedUD = false
        /// The two rules added in phase 2 (one token per position, copy
        /// values exactly); off gives phase 0's v1 rule set.
        public var extraRules = true
        /// Glosses after UD feature and relation values (POS is always
        /// glossed).
        public var glossFeatures = true

        public init(firstLevel: Int = 0, retrieveExamples: Bool = true,
                    curatedUD: Bool = false, extraRules: Bool = true, glossFeatures: Bool = true) {
            self.glossFeatures = glossFeatures
            self.firstLevel = firstLevel
            self.retrieveExamples = retrieveExamples
            self.curatedUD = curatedUD
            self.extraRules = extraRules
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
                           options: options)
            if countTokens(prompt.system) + countTokens(prompt.user) <= budget { break }
        }
        return prompt
    }

    static func build(
        profile: CorpusProfile, request: String, examples: [ExampleBank.Example], detail: Detail,
        options: Options = .init()
    ) -> QueryPrompt {
        let chosen = options.retrieveExamples
            ? ExampleBank.select(examples, for: request, count: detail.examples, fixed: fixedExamples)
            : Array(examples.prefix(detail.examples))
        let rules = options.extraRules ? rules : baseRules
        var system = rules + "\n\n" + corpusFacts(profile, detail: detail, curatedUD: options.curatedUD,
                                                    glossFeatures: options.glossFeatures)
        if !chosen.isEmpty {
            system += "\n\nExamples:\n" + chosen.map {
                "Request: \($0.request)\n\($0.plan.compactJSON)"
            }.joined(separator: "\n\n")
        }
        return QueryPrompt(system: system, user: "Request: \(request)",
                           exampleRequests: chosen.map(\.request))
    }

    /// The bank's first examples are in every prompt, whatever the request;
    /// only the rest are retrieved. Retrieval by word overlap tends to pick
    /// an example about the same part of speech with a different
    /// structure ("proper nouns in the plural" → "a sequence of proper
    /// nouns"), which a small model then copies (docs/nl-query-assistant.md,
    /// "Phase 2 results").
    static let fixedExamples = 3

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
        - Copy tag, feature and structure values exactly as listed below: same spelling, same upper and lower case, same singular or plural.
        """

    /// Phase 0's v1 rules, for comparison (`Options.extraRules`).
    static let baseRules = """
        You turn a linguist's request into a corpus search pattern. Output only the QueryPlan object.

        How a QueryPlan works:
        - "positions" is a sequence of consecutive tokens (words). Each position lists conditions that must ALL hold for that token.
        - A condition compares one token attribute with a value. Values are exact strings or regular expressions over the whole value (".*" = anything, "a|b" = either, "un.*" = starts with "un"). Matching is case-sensitive.
        - A position with no conditions matches any single token.
        - "repeat": "once" (normal), "optional" (0 or 1 tokens), "zero-or-more", "one-or-more". Use "optional" or "zero-or-more" on an empty position to allow gaps between words.
        - "within" restricts the whole match to structures (e.g. documents) with a given attribute value. Leave it empty unless the request names one.
        - Use lemma for "any form of" a word (lemma "go" matches go, went, gone). Use word for an exact word form.
        """

    // MARK: Corpus facts

    static func corpusFacts(_ profile: CorpusProfile, detail: Detail, curatedUD: Bool = false,
                            glossFeatures: Bool = true) -> String {
        let names = Set(profile.attributes.map(\.name))
        let preferred = [profile.attribute(for: .udPOS), profile.attribute(for: .udFeatures)]
            .compactMap { $0?.name }
        var lines = ["This corpus has these token attributes:"]
        for attribute in profile.attributes {
            lines.append("- " + describe(attribute, detail: detail, allNames: names,
                                         preferred: preferred, curatedUD: curatedUD,
                                         glossFeatures: glossFeatures))
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

    /// - Parameter preferred: the UD POS and features attributes, if the
    ///   corpus has them. Another tagset beside them (UD's language-specific
    ///   `xpos`) is then described as secondary: listed prominently, it
    ///   drew a small model into `xpos="VBG"` where `feats="VerbForm=Ger"`
    ///   was meant (docs/nl-query-assistant.md, "Phase 2 results").
    static func describe(_ a: CorpusProfile.Attribute, detail: Detail, allNames: Set<String>,
                         preferred: [String] = [], curatedUD: Bool = false,
                         glossFeatures: Bool = true) -> String {
        let glosses = TagsetGlosses.shared
        let present = a.topValues.lazy.map(\.value).filter { !["_", ""].contains($0) }
        /// With `curatedUD`, a UD attribute lists the glossed values it
        /// has, in the gloss table's (linguistic) order, like the
        /// hand-curated lists of phase 0's v1 prompt. See `Options.curatedUD`.
        func values(_ gloss: [String: String]?, order: [String]?) -> [String] {
            guard curatedUD, let gloss, let order else { return Array(present) }
            let have = Set(present)
            return order.filter { have.contains($0) && gloss[$0] != nil }
        }
        func listed(_ limit: Int, _ gloss: [String: String]? = nil, order: [String]? = nil,
                    showGloss: Bool = true, fallback: ((String) -> String?)? = nil) -> String {
            values(gloss, order: order).prefix(limit).map { v in
                if showGloss, let g = gloss?[v] ?? fallback?(v) { return "\(v) – \(g)" }
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
                + listed(.max, glosses.udPOS, order: glosses.order.udPOS)
        case .udFeatures:
            return "\(a.name)\(label): morphological features, one Feature=Value per condition:\n"
                + groupedFeatures(a, limit: detail.udFeatures,
                                  glosses: glossFeatures ? glosses.udFeatures : [:],
                                  order: curatedUD ? glosses.order.udFeatures : nil)
        case .udRelation:
            return "\(a.name)\(label): syntactic relation to the parent word (Universal Dependencies): "
                + listed(detail.udRelations, glosses.udRelation, order: glosses.order.udRelation,
                         showGloss: glossFeatures) { value in
                    // An unlisted subtype (`obl:arg`) is still its base relation.
                    value.split(separator: ":").first.flatMap { glosses.udRelation[String($0)] }
                        .map { "\($0), subtype" }
                }
        case .czechPositionalTag:
            return "\(a.name)\(label): Czech " + glosses.czechPositionalTag.joined(separator: "\n    ")
        case .other:
            if !preferred.isEmpty, looksLikeTagset(a) {
                let prefer = preferred.joined(separator: " and ")
                let sample = detail.otherValues > 0 ? ", e.g. " + listed(min(detail.otherValues, 10)) : ""
                return "\(a.name)\(label): a second, language-specific tagset\(sample). Prefer \(prefer)."
            }
            guard detail.otherValues > 0 else { return "\(a.name)\(label)" }
            return "\(a.name)\(label), values such as: " + listed(detail.otherValues)
        }
    }

    /// One line per feature (`Number=Sing – singular; Number=Plur – plural`),
    /// features in order of their most frequent value. A flat frequency
    /// list scatters a feature's values across 60 items and puts the rare
    /// ones people ask about (`Degree=Sup`, `Mood=Imp`) where a small model
    /// stops reading.
    static func groupedFeatures(
        _ a: CorpusProfile.Attribute, limit: Int, glosses: [String: String], order curated: [String]? = nil
    ) -> String {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        var values = a.topValues.map(\.value).filter { CorpusProfile.isUDFeature($0) }
        if let curated {
            let have = Set(values)
            values = curated.filter { have.contains($0) }
        }
        for v in values.prefix(limit) {
            let feature = String(v.prefix { $0 != "=" })
            if groups[feature] == nil { order.append(feature) }
            groups[feature, default: []].append(glosses[v].map { "\(v) – \($0)" } ?? v)
        }
        return order.map { "    " + groups[$0]!.joined(separator: "; ") }.joined(separator: "\n")
    }

    /// Short codes, not many of them: a tagset rather than words or numbers.
    static func looksLikeTagset(_ a: CorpusProfile.Attribute) -> Bool {
        let values = a.topValues.map(\.value)
        return !values.isEmpty && values.count < CorpusProfile.valueSampleSize
            && values.allSatisfy { $0.count <= 8 && !$0.contains(" ") }
            && values.contains { $0.contains { $0.isLetter } }
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
    /// Each table's keys in file order, which is the curated order the
    /// prompt lists them in (a Swift dictionary doesn't keep it).
    var order = Order()

    struct Order {
        var udPOS: [String] = []
        var udRelation: [String] = []
        var udFeatures: [String] = []
    }

    enum CodingKeys: String, CodingKey {
        case udPOS, udRelation, udFeatures, czechPositionalTag
    }

    static let shared: TagsetGlosses = {
        var glosses: TagsetGlosses = load("TagsetGlosses")
        glosses.order = Order(udPOS: keyOrder("udPOS"), udRelation: keyOrder("udRelation"),
                              udFeatures: keyOrder("udFeatures"))
        return glosses
    }()

    /// The keys of one object in TagsetGlosses.json in the order written.
    /// JSONDecoder and JSONSerialization both lose it, so this scans the
    /// file's text: the tables are flat string maps, one `"key": "gloss"`
    /// per line.
    static func keyOrder(_ table: String) -> [String] {
        guard let url = Bundle.module.url(forResource: "TagsetGlosses", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let start = text.range(of: "\"\(table)\": {")
        else { return [] }
        let body = text[start.upperBound...].prefix { $0 != "}" }
        return body.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), let end = t.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(t[t.index(after: t.startIndex)..<end])
        }
    }
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

    /// The first `fixed` examples, then the ones sharing the most words
    /// with the request, `count` in all; ties go in bank order, which puts
    /// the basic patterns first when nothing matches.
    static func select(_ examples: [Example], for request: String, count: Int,
                       fixed: Int = 0) -> [Example] {
        let fixed = min(fixed, count, examples.count)
        let wanted = keywords(request)
        let scores: [Int] = examples.map { keywords($0.request).intersection(wanted).count }
        let ranked: [Int] = examples.indices.dropFirst(fixed).sorted { a, b in
            scores[a] != scores[b] ? scores[a] > scores[b] : a < b
        }
        return (Array(0..<fixed) + ranked.prefix(count - fixed).sorted()).map { examples[$0] }
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
