import Cocoa

/// A single Left/Match/Right cell - monospaced, with the matched span in
/// bold accent color, mirroring the KWIC styling from the earlier SwiftUI
/// prototype (`ContentView.KWICRow`).
final class KWICCellView: NSTableCellView {
    enum Style { case plain, highlighted }

    private let label = NSTextField(labelWithString: "")

    // Current content, kept around so mouse-tracking callbacks can hit-test
    // against it - see `updateTrackingAreas`/`mouseMoved`/`mouseEntered`.
    private var displayLine = KWICDisplayLine(segments: [], tokenTooltips: [])
    private var alignment: NSTextAlignment = .left
    private var style: Style = .plain
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isBordered = false
        label.isEditable = false
        label.drawsBackground = false
        // Belt and suspenders against wrapping-driven row-height blowup
        // (see `configure`'s paragraph-style comment) - forces single-line
        // rendering regardless of what's ever assigned to
        // `attributedStringValue` in the future, not just today's code path.
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// The inset the label sits at from the cell's own edges (see the
    /// leading/trailing constraints above) - needed to convert a
    /// cell-relative mouse point into a label-relative one before calling
    /// `tokenTooltip(for:alignment:style:labelWidth:at:)`.
    static let labelInset: CGFloat = 4

    /// `displayLine.segments` (see `KWICFormatter.displayLine`) are combined
    /// into one attributed string - `.word` segments get the column's own
    /// `style` (plus a per-script font override, if configured - see
    /// `wordFont`), `.secondaryAttribute` segments always render in
    /// `AppSettings.shared.positionalAttributeColor` at the plain
    /// (non-bold) base font regardless of `style`, so an inline attribute
    /// reads as clearly secondary even in the bold/accent-colored KWIC
    /// column.
    func configure(displayLine: KWICDisplayLine, alignment: NSTextAlignment, style: Style) {
        wantsLayer = false
        layer?.backgroundColor = nil
        label.alignment = alignment
        label.lineBreakMode = alignment == .right ? .byTruncatingHead : .byTruncatingTail
        label.attributedStringValue = Self.attributedString(
            for: displayLine.segments, alignment: alignment, style: style)

        self.displayLine = displayLine
        self.alignment = alignment
        self.style = style
    }

    /// The inline "Extended Context" display mode (see
    /// `ConcordanceViewController`'s row-view overlay) needs one
    /// continuous, word-wrapped paragraph spanning the whole row - not
    /// three separate Left/Match/Right strings - so the match reads as
    /// part of a normal sentence rather than as three disconnected
    /// fragments. Lives here (not on the overlay field itself) purely to
    /// reuse this file's font/color conventions.
    static func extendedContextParagraph(before: String, match: String, after: String) -> NSAttributedString {
        let baseFont = AppSettings.shared.resultsFont
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = .left

        let result = NSMutableAttributedString()
        func append(_ text: String, font: NSFont, color: NSColor) {
            guard !text.isEmpty else { return }
            if result.length > 0 {
                result.append(NSAttributedString(string: " ", attributes: [.font: baseFont, .paragraphStyle: paragraphStyle]))
            }
            result.append(NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle]))
        }
        append(before, font: baseFont, color: .labelColor)
        append(match, font: boldFont, color: .controlAccentColor)
        append(after, font: baseFont, color: .labelColor)
        return result
    }

    /// The height `paragraph` (from `extendedContextParagraph`) needs to
    /// word-wrap within `width` - shared by `ConcordanceViewController
    /// .tableView(_:heightOfRow:)` so the row is sized to exactly match
    /// what the overlay is about to render, not a guess.
    static func extendedContextHeight(for paragraph: NSAttributedString, width: CGFloat) -> CGFloat {
        guard paragraph.length > 0 else { return 0 }
        let bounding = paragraph.boundingRect(
            with: NSSize(width: max(width, 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounding.height)
    }

    /// Per-token hover tooltips via manual mouse tracking - see
    /// docs/project-plan.md's Phase 5.3 writeup for the full diagnostic
    /// history (an `NSTableViewDelegate`-based attempt never fired for this
    /// view-based table; a whole-line `.toolTip`-only approach was also
    /// tried and hit the exact same "doesn't show until one app-switch
    /// after launch" quirk, ruling out the tooltip mechanism itself as the
    /// cause). Kept as the per-token version since it's strictly better UX
    /// once that quirk resolves itself (by user action or an OS update) and
    /// reverting to whole-line bought nothing.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // `.inVisibleRect` keeps this in sync with the view's *current*
        // bounds automatically (including after later resizes), so the
        // `rect: .zero` here is just a placeholder - AppKit ignores it in
        // favor of tracking the live visible rect. `.activeAlways`, not
        // `.activeInKeyWindow` - doesn't fix the known launch-time quirk
        // (see above) but is still the more correct/robust choice
        // regardless, since it doesn't depend on window/app active-state
        // detection at all once hover does start working.
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolTip(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateToolTip(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        toolTip = nil
    }

    private func updateToolTip(for event: NSEvent) {
        guard !displayLine.tokenTooltips.isEmpty else {
            toolTip = nil
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let labelWidth = max(bounds.width - Self.labelInset * 2, 0)
        toolTip = Self.tokenTooltip(
            for: displayLine, alignment: alignment, style: style,
            labelWidth: labelWidth, at: point.x - Self.labelInset)?.text
    }

    /// Locates whichever token (if any) covers horizontal position `x`
    /// (relative to the label's own left edge, i.e. already adjusted for
    /// `labelInset`) within `displayLine`, rendered at `labelWidth` with
    /// the given `alignment`/`style` - returns its tooltip text.
    ///
    /// Sums individually-measured segment widths rather than measuring the
    /// whole string at once - accurate for this app's monospaced results
    /// font (every character/weight shares one advance width, so the sum
    /// matches how the whole string actually lays out); not exact for a
    /// proportional font, and not adjusted for truncation when the
    /// rendered text is wider than the cell - a token past the truncated
    /// "…" can't be hovered precisely either way, since its glyphs were
    /// never drawn.
    static func tokenTooltip(
        for displayLine: KWICDisplayLine, alignment: NSTextAlignment, style: Style,
        labelWidth: CGFloat, at x: CGFloat
    ) -> (text: String, rect: CGRect)? {
        guard !displayLine.tokenTooltips.isEmpty else { return nil }

        let segmentWidths = displayLine.segments.map { width(of: $0, style: style) }
        var segmentStartX: [CGFloat] = []
        var cursor: CGFloat = 0
        for segmentWidth in segmentWidths {
            segmentStartX.append(cursor)
            cursor += segmentWidth
        }
        let totalWidth = cursor
        let originX: CGFloat
        switch alignment {
        case .right: originX = labelWidth - totalWidth
        case .center: originX = (labelWidth - totalWidth) / 2
        default: originX = 0
        }

        for tooltip in displayLine.tokenTooltips {
            guard let first = tooltip.segmentRange.first, let last = tooltip.segmentRange.last,
                  segmentStartX.indices.contains(first), segmentWidths.indices.contains(last) else { continue }
            let startX = originX + segmentStartX[first]
            let endX = originX + segmentStartX[last] + segmentWidths[last]
            guard x >= startX, x < endX else { continue }
            return (tooltip.text, CGRect(x: startX, y: 0, width: endX - startX, height: 1))
        }
        return nil
    }

    private static func width(of segment: KWICDisplaySegment, style: Style) -> CGFloat {
        let baseFont = AppSettings.shared.resultsFont
        let font: NSFont = segment.kind == .secondaryAttribute ? baseFont : wordFont(for: segment, baseFont: baseFont, style: style)
        return NSAttributedString(string: segment.text, attributes: [.font: font]).size().width
    }

    /// `.word`-kind segments (actual token text, not a secondary-attribute
    /// suffix) get a per-script font override if `AppSettings.shared
    /// .scriptFontOverrides` has one for that segment's dominant script
    /// (see `UnicodeScript`) - e.g. a corpus mixing Latin and Cyrillic text
    /// where one font's glyph coverage isn't ideal for both. Falls back to
    /// `baseFont` (`resultsFont`) with no override configured, same as
    /// before this setting existed.
    private static func wordFont(for segment: KWICDisplaySegment, baseFont: NSFont, style: Style) -> NSFont {
        let script = UnicodeScript.dominant(in: segment.text)
        let overrideName = AppSettings.shared.scriptFontOverrides[script.rawValue]
        let resolvedBase = overrideName.flatMap { NSFont(name: $0, size: baseFont.pointSize) } ?? baseFont
        return style == .highlighted ? NSFontManager.shared.convert(resolvedBase, toHaveTrait: .boldFontMask) : resolvedBase
    }

    /// NSTextField.attributedStringValue does NOT pick up the field's own
    /// `lineBreakMode`/`alignment` properties the way `.stringValue` does -
    /// without an explicit paragraph style baked into the string itself, it
    /// silently falls back to wrapping. That blew up each row's actual
    /// rendered height past what the table view allocated for it, producing
    /// cumulative overlapping/ghosting further down the table (screenshot,
    /// 2026-09-07). Baking the paragraph style into the string itself,
    /// rather than relying on the field's properties, is the fix.
    private static func attributedString(
        for segments: [KWICDisplaySegment], alignment: NSTextAlignment, style: Style
    ) -> NSAttributedString {
        let baseFont = AppSettings.shared.resultsFont
        let wordColor: NSColor = style == .highlighted ? .controlAccentColor : .labelColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = alignment == .right ? .byTruncatingHead : .byTruncatingTail
        paragraphStyle.alignment = alignment

        let attributed = NSMutableAttributedString()
        for segment in segments {
            let (font, color): (NSFont, NSColor) = segment.kind == .secondaryAttribute
                ? (baseFont, AppSettings.shared.positionalAttributeColor)
                : (wordFont(for: segment, baseFont: baseFont, style: style), wordColor)
            attributed.append(NSAttributedString(
                string: segment.text,
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle]))
        }
        return attributed
    }

    /// A small colored badge for the leading "Group" column - table-native
    /// (a narrow tinted column), rather than repainting the whole row.
    func configureGroup(_ group: Int) {
        label.alignment = .center
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        guard group > 0 else {
            label.stringValue = ""
            wantsLayer = false
            layer?.backgroundColor = nil
            return
        }
        label.stringValue = "\(group)"
        label.textColor = .white
        wantsLayer = true
        layer?.backgroundColor = Self.color(forGroup: group).cgColor
        layer?.cornerRadius = 4
    }

    private static func color(forGroup group: Int) -> NSColor {
        let palette: [NSColor] = [
            .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal,
            .systemBlue, .systemPurple, .systemPink, .systemBrown,
        ]
        return palette[(group - 1) % palette.count]
    }

    /// The "Doc" column - one structural attribute value (e.g.
    /// "doc.title"), constant for the whole line, so styled as a small
    /// secondary label (like `configureGroup`'s badge) rather than routed
    /// through `KWICFormatter`'s per-token segment machinery.
    func configureStructuralInfo(_ value: String) {
        wantsLayer = false
        layer?.backgroundColor = nil
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 11)
        label.textColor = AppSettings.shared.structuralAttributeColor
        label.stringValue = value
    }
}
