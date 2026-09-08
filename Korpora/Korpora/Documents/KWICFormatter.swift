import Foundation
import ManateeKit

/// One piece of a KWIC cell's inline display - either a token's main word
/// text/inter-token space, or one of its secondary-attribute values, so a
/// caller can render them with different styling (e.g. secondary
/// attributes in a muted color) without this file depending on AppKit.
struct KWICDisplaySegment: Equatable {
    enum Kind: Equatable { case word, secondaryAttribute }
    let text: String
    let kind: Kind
}

/// One token's hover-tooltip text, located by which of `KWICDisplayLine
/// .segments` it covers (always a contiguous run: that token's word
/// segment, plus its secondary-attribute suffix segment if it has one) -
/// lets a view layer map a hovered screen position to a segment, then to
/// this range, then to *this specific token's* tooltip, rather than
/// showing one combined tooltip for the whole cell regardless of which
/// word the mouse is actually over.
struct KWICTokenTooltip: Equatable {
    let segmentRange: Range<Int>
    let text: String
}

/// `segments` is what's rendered; `tokenTooltips` locates each token's
/// hover text within that same segment list, computed in the same pass so
/// the two can never drift out of alignment with each other.
struct KWICDisplayLine: Equatable {
    let segments: [KWICDisplaySegment]
    let tokenTooltips: [KWICTokenTooltip]
}

/// Pure formatting logic for turning a `KWICLine` segment's tokens into what
/// `KWICCellView` actually displays - kept separate from both
/// `ManateeKit.KWICToken` (an engine-layer model with no display opinion)
/// and `KWICCellView` (an AppKit view with no formatting opinion), so it's
/// unit-testable without either a live corpus or a window.
///
/// Inline and tooltip display are independent per attribute, not an
/// either/or mode for the whole document - e.g. "tag" inline and "lemma"
/// only on hover, at the same time, is a real combination a user asked for
/// (KonText separates "corpus view" attribute placement per attribute
/// too). `ConcordanceDocument.inlineAttributes`/`.tooltipAttributes` are
/// the two independent lists this function reads.
enum KWICFormatter {
    static func displayLine(for tokens: [KWICToken], inlineAttributes: [String], tooltipAttributes: [String]) -> KWICDisplayLine {
        var segments: [KWICDisplaySegment] = []
        var tooltips: [KWICTokenTooltip] = []

        func append(_ text: String, kind: KWICDisplaySegment.Kind) {
            guard !text.isEmpty else { return }
            segments.append(KWICDisplaySegment(text: text, kind: kind))
        }

        for (index, token) in tokens.enumerated() {
            if index > 0 {
                append(" ", kind: .word)
            }
            let tokenSegmentStart = segments.count
            append(token.word, kind: .word)
            if !inlineAttributes.isEmpty {
                let extras = inlineAttributes.compactMap { token.secondaryAttributes[$0] }
                if !extras.isEmpty {
                    append("/" + extras.joined(separator: "/"), kind: .secondaryAttribute)
                }
            }
            if !tooltipAttributes.isEmpty {
                let extras = tooltipAttributes.compactMap { attribute in
                    token.secondaryAttributes[attribute].map { "\(attribute): \($0)" }
                }
                if !extras.isEmpty {
                    tooltips.append(KWICTokenTooltip(
                        segmentRange: tokenSegmentStart..<segments.count, text: extras.joined(separator: ", ")))
                }
            }
        }
        return KWICDisplayLine(segments: segments, tokenTooltips: tooltips)
    }
}
