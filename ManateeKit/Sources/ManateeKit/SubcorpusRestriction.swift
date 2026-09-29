import Foundation

/// The restriction string `Corpus.createSubcorpus(named:structure:query:)`
/// takes, built from values picked in a list instead of typed as CQL
/// (docs/project-plan.md, 6.9 - KonText's "Text Types" picking).
///
/// Values picked for one attribute are alternatives (`OR`); different
/// attributes all have to hold (`AND`) - the same as KonText: pick two
/// genres and one year and you get documents of either genre from that
/// year. Attribute names are the structure's own (`genre`, not
/// `doc.genre`): `create_subcorpus` evaluates the query with the structure
/// as its corpus (see `Corpus.createSubcorpus`).
public struct SubcorpusRestriction: Equatable, Sendable {
    public struct Selection: Equatable, Sendable {
        public var attribute: String
        public var values: [String]

        public init(attribute: String, values: [String]) {
            self.attribute = attribute
            self.values = values
        }
    }

    public var selections: [Selection]

    public init(selections: [Selection] = []) {
        self.selections = selections
    }

    /// `genre="fiction"` for one value, `(genre="fiction"|genre="essay")`
    /// for several, joined with ` & ` across attributes. Empty when
    /// nothing is selected. Attributes with no values are skipped.
    public var query: String {
        selections.compactMap { selection -> String? in
            let terms = selection.values.map { "\(selection.attribute)=\(Self.literal($0))" }
            switch terms.count {
            case 0: return nil
            case 1: return terms[0]
            default: return "(" + terms.joined(separator: "|") + ")"
            }
        }.joined(separator: " & ")
    }

    public var isEmpty: Bool { query.isEmpty }

    /// A CQL string literal that matches exactly `value`. CQL compares
    /// against a *regular expression* for the whole value, so a picked
    /// value like `Smith (Jr.)` has to be regex-escaped first; the result is
    /// then quoted the way manatee's lexer unquotes (`\\` and `\"`, nothing
    /// else - see `unescapeString` in manatee-open/query/cqpeval.y).
    public static func literal(_ value: String) -> String {
        quoted(regexEscaped(value))
    }

    /// `value` with every regular-expression metacharacter escaped.
    public static func regexEscaped(_ value: String) -> String {
        var out = ""
        for character in value {
            if #"\.^$*+?()[]{}|"#.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// The pattern for a "contains" search box: `text` matched anywhere in
    /// a value. For `Corpus.attributeValues(attribute:matching:...)`, which
    /// matches the whole value.
    public static func containsPattern(_ text: String) -> String {
        ".*" + regexEscaped(text) + ".*"
    }

    private static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
