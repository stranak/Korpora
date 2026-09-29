import Foundation
import ManateeKit

/// What the query assistant knows about one corpus: its attributes, a
/// frequency sample of each one's values, and the role each attribute
/// plays (docs/nl-query-assistant.md, "Corpus facts in the prompt").
///
/// Gathered once per corpus by `gather(from:)`; everything after that
/// (role detection, prompt building) is pure, so it's unit-tested with
/// hand-made profiles instead of real corpora.
public struct CorpusProfile: Sendable {
    public var info: CorpusInfo
    /// Positional attributes, in registry order.
    public var attributes: [Attribute]
    /// Structure attributes (`doc.genre`), in registry order.
    public var structureAttributes: [StructureAttribute]

    public struct Attribute: Sendable, Equatable {
        public var name: String
        /// The registry's `LABEL`, if the corpus author wrote one.
        public var label: String?
        /// Most frequent values first. For a MULTIVALUE attribute these are
        /// the single values (`Number=Sing`), not the combinations the
        /// lexicon also holds, since a condition matches one at a time.
        public var topValues: [ValueCount]
        public var role: Role = .other
    }

    public struct StructureAttribute: Sendable, Equatable {
        /// Dotted, `doc.genre`.
        public var name: String
        public var label: String?
        /// Most frequent first, counted in structures (documents), not tokens.
        public var topValues: [ValueCount]
        /// Every value was sampled: `topValues` is the whole value set.
        public var isComplete: Bool

        /// Few values that each recur: a category like genre, worth listing
        /// in the prompt. An identifier (`doc.id`: every value once) or a
        /// free-text field (a title) isn't.
        public var isCategorical: Bool {
            isComplete && !topValues.isEmpty && (topValues.first?.count ?? 0) > 1
        }
    }

    public struct ValueCount: Sendable, Equatable {
        public var value: String
        public var count: Int

        public init(value: String, count: Int) {
            self.value = value
            self.count = count
        }
    }

    /// What an attribute's values are, so the prompt can explain them and
    /// the example bank can use them. Detected from the values themselves,
    /// not the name: UD English EWT calls its part of speech `upos`, the
    /// EU DGT-UD corpora call the same thing `pos`, and SYN2025's `pos` is
    /// the first letter of a Czech positional tag.
    public enum Role: String, Sendable, Equatable {
        case word, lemma
        case udPOS, udFeatures, udRelation
        case czechPositionalTag
        case other
    }

    public enum TagsetFamily: Sendable, Equatable {
        case ud, czechPositional, generic
    }

    static let valueSampleSize = 120
    static let structureValueLimit = 30

    /// The attribute playing `role`, if any - the first one, in registry
    /// order, when several do (UD English has only one `upos`, but a
    /// corpus may carry a parent's copy such as `p_upos` too, and that's
    /// listed after the token's own).
    public func attribute(for role: Role) -> Attribute? {
        attributes.first { $0.role == role }
    }

    public var tagsetFamily: TagsetFamily {
        if attribute(for: .udPOS) != nil { return .ud }
        if attribute(for: .czechPositionalTag) != nil { return .czechPositional }
        return .generic
    }
}

// MARK: - Gathering

extension CorpusProfile {
    public static func gather(from corpus: Corpus) async throws -> CorpusProfile {
        let info = try await corpus.info()
        var attributes: [Attribute] = []
        for name in info.attributes {
            let separator = try await multiValueSeparator(corpus, name)
            // The lexicon of a MULTIVALUE attribute holds single values
            // *and* every combination seen (UD EWT feats: 64 + 220); only
            // the singles are useful as condition values, so sample extra
            // and drop the combinations.
            let limit = separator == nil ? valueSampleSize : valueSampleSize * 4
            var values = try await corpus.topAttributeValues(attribute: name, limit: limit)
                .map { ValueCount(value: $0.value, count: $0.frequency) }
            if let separator {
                values = values.filter { !$0.value.contains(separator) }
            }
            attributes.append(Attribute(
                name: name, label: try await label(corpus, name),
                topValues: Array(values.prefix(valueSampleSize))))
        }
        var structureAttributes: [StructureAttribute] = []
        for name in QuerySchema.structureAttributeNames(info) {
            let values = try await corpus.topAttributeValues(
                attribute: name, limit: structureValueLimit + 1)
            structureAttributes.append(StructureAttribute(
                name: name, label: try await label(corpus, name),
                topValues: values.prefix(structureValueLimit)
                    .map { ValueCount(value: $0.value, count: $0.frequency) },
                isComplete: values.count <= structureValueLimit))
        }
        var profile = CorpusProfile(
            info: info, attributes: attributes, structureAttributes: structureAttributes)
        profile.detectRoles()
        return profile
    }

    private static func label(_ corpus: Corpus, _ name: String) async throws -> String? {
        let label = try await corpus.registryValue("\(name).LABEL")
        return label.isEmpty ? nil : label
    }

    /// The registry's MULTISEP when MULTIVALUE is on. An unset MULTIVALUE
    /// reads as `n`, and manatee's own test is the first letter.
    private static func multiValueSeparator(_ corpus: Corpus, _ name: String) async throws -> String? {
        let multi = try await corpus.registryValue("\(name).MULTIVALUE").lowercased()
        guard multi.hasPrefix("y") || multi == "1" || multi == "true" else { return nil }
        let separator = try await corpus.registryValue("\(name).MULTISEP")
        return separator.isEmpty ? "," : separator
    }
}

// MARK: - Role detection

extension CorpusProfile {
    static let upos: Set<String> = [
        "ADJ", "ADP", "ADV", "AUX", "CCONJ", "DET", "INTJ", "NOUN", "NUM",
        "PART", "PRON", "PROPN", "PUNCT", "SCONJ", "SYM", "VERB", "X",
    ]

    /// UD's universal relations; language-specific subtypes (`acl:relcl`,
    /// `nsubj:pass`) are matched by the part before the colon.
    static let udRelations: Set<String> = [
        "nsubj", "obj", "iobj", "csubj", "ccomp", "xcomp", "obl", "vocative",
        "expl", "dislocated", "advcl", "advmod", "discourse", "aux", "cop",
        "mark", "nmod", "appos", "nummod", "acl", "amod", "det", "clf", "case",
        "conj", "cc", "fixed", "flat", "compound", "list", "parataxis",
        "orphan", "goeswith", "reparandum", "punct", "root", "dep",
    ]

    /// Values that carry no information in any tagset: UD's `_` for "no
    /// value", the empty string, a dash.
    private static let blanks: Set<String> = ["_", "", "-"]

    /// Share of the sample (by frequency) a role's test has to accept.
    /// Below 1 so that a few stray values (a tagger's `X`, a typo) don't
    /// make an attribute unrecognizable.
    static let roleThreshold = 0.9

    mutating func detectRoles() {
        for i in attributes.indices {
            attributes[i].role = Self.role(of: attributes[i])
        }
    }

    static func role(of attribute: Attribute) -> Role {
        switch attribute.name {
        case "word": return .word
        case "lemma": return .lemma
        default: break
        }
        let values = attribute.topValues.filter { !blanks.contains($0.value) }
        guard !values.isEmpty else { return .other }

        func share(_ accepts: (String) -> Bool) -> Double {
            let total = values.reduce(0) { $0 + $1.count }
            guard total > 0 else { return 0 }
            return Double(values.filter { accepts($0.value) }.reduce(0) { $0 + $1.count }) / Double(total)
        }
        func distinct(_ accepts: (String) -> Bool) -> Int {
            values.filter { accepts($0.value) }.count
        }

        // A handful of UPOS values could be any tagset's (NOUN, X); UD's
        // is recognized only when enough of it is actually present.
        if share(upos.contains) >= roleThreshold, distinct(upos.contains) >= 8 {
            return .udPOS
        }
        let isRelation = { (v: String) in udRelations.contains(String(v.split(separator: ":").first ?? "")) }
        if share(isRelation) >= roleThreshold, distinct(isRelation) >= 8 {
            return .udRelation
        }
        if share(isUDFeature) >= roleThreshold, distinct(isUDFeature) >= 3 {
            return .udFeatures
        }
        if share(isCzechPositionalTag) >= roleThreshold {
            return .czechPositionalTag
        }
        return .other
    }

    /// `Number=Sing`, `Person[psor]=3`: an uppercase feature name, an
    /// optional bracketed layer, `=`, a value.
    static func isUDFeature(_ value: String) -> Bool {
        value.wholeMatch(of: #/[A-Z][A-Za-z0-9]*(\[[a-z0-9]+\])?=[A-Za-z0-9,]+/#) != nil
    }

    /// A 15-character Prague positional tag (PDT / MorfFlex, SYN corpora):
    /// part of speech in position 1, `-` for positions that don't apply.
    static func isCzechPositionalTag(_ value: String) -> Bool {
        guard value.count == 15, let first = value.first, first.isUppercase, first.isASCII else {
            return false
        }
        return value.contains("-")
    }
}
