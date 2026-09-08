import Foundation
import ManateeKit

enum ConcordanceExportFormat {
    case commaSeparated
    case tabSeparated
}

/// Turns concordance rows into exportable text - pure, AppKit-free logic
/// (mirrors `KWICFormatter`'s own precedent for keeping formatting
/// separate from file/panel plumbing), so it's unit-testable without a
/// live corpus or a window. Exports exactly the four columns visible in
/// the table (Group, Left, Match, Right) - whatever sort/filter/sample/
/// line-groups are currently applied, since it reads `rows` as given
/// rather than re-querying anything.
enum ConcordanceExporter {
    /// `inlineAttributes`, when non-empty, appends each listed attribute's
    /// value in brackets after its token (e.g. "fox[NN]") - unlike the
    /// on-screen KWIC display (`KWICFormatter`), a plain-text cell has no
    /// separate column/color to hang a secondary attribute off of, and Left/
    /// Match/Right can each hold many words, so "in brackets after each
    /// word" (rather than, say, one combined suffix per cell) is what keeps
    /// each value attached to the word it actually describes.
    static func export(rows: [ConcordanceRow], format: ConcordanceExportFormat, inlineAttributes: [String] = []) -> String {
        let separator = format == .commaSeparated ? "," : "\t"
        var lines = [join(["Group", "Left", "Match", "Right"], separator: separator, format: format)]
        for row in rows {
            lines.append(join(
                [String(row.group),
                 text(for: row.line.leftTokens, inlineAttributes: inlineAttributes),
                 text(for: row.line.kwicTokens, inlineAttributes: inlineAttributes),
                 text(for: row.line.rightTokens, inlineAttributes: inlineAttributes)],
                separator: separator, format: format))
        }
        // CRLF, not LF - the conventional CSV/TSV line ending (RFC 4180),
        // and harmless either way for a plain-text viewer.
        return lines.joined(separator: "\r\n")
    }

    private static func text(for tokens: [KWICToken], inlineAttributes: [String]) -> String {
        guard !inlineAttributes.isEmpty else {
            return tokens.map(\.word).joined(separator: " ")
        }
        return tokens.map { token in
            let extras = inlineAttributes.compactMap { token.secondaryAttributes[$0] }
            guard !extras.isEmpty else { return token.word }
            return "\(token.word)[\(extras.joined(separator: "/"))]"
        }.joined(separator: " ")
    }

    private static func join(_ fields: [String], separator: String, format: ConcordanceExportFormat) -> String {
        fields.map { field($0, format: format) }.joined(separator: separator)
    }

    private static func field(_ value: String, format: ConcordanceExportFormat) -> String {
        switch format {
        case .tabSeparated:
            // TSV has no standard escaping convention the way CSV's
            // quoting does - a literal tab/newline in real corpus text
            // would silently break column alignment, so replace rather
            // than try to escape it.
            return value.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        case .commaSeparated:
            guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
                return value
            }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }
}
