import Foundation
import Testing

@testable import Korpora

/// Phase 6.6a item 2: the inline Extended Context paragraph must start to
/// the right of the leading metadata columns (disclosure triangle, line
/// group, structural attribute) instead of spanning the literal full row
/// width the way 6.6 had it - otherwise it renders over the "Doc" value,
/// and over the disclosure triangle it would make collapsing impossible.
///
/// Only the arithmetic is tested here. It's deliberately split out of
/// `ConcordanceViewController.overlayLeadingInset()` as a static pure
/// function precisely so it's reachable without a live, laid-out
/// `NSTableView` - the column geometry it feeds on isn't.
struct ExtendedContextOverlayInsetTests {
    /// No metadata column showing (no structural attribute chosen, no
    /// line groups, triangle off) - the paragraph starts at the same 8pt
    /// text padding the overlay used against the row edge in 6.6, so this
    /// case must be byte-for-byte the old behavior.
    @Test func noVisibleMetadataColumnsGivesPlainTextPadding() {
        let inset = ConcordanceViewController.overlayLeadingInset(visibleMetadataColumnWidths: [])
        #expect(inset == 8)
    }

    /// One column: its own width, the intercell gap that follows it, then
    /// the text padding.
    @Test func oneVisibleColumnAddsItsWidthTheGapAndThePadding() {
        let inset = ConcordanceViewController.overlayLeadingInset(
            visibleMetadataColumnWidths: [120], intercellSpacing: 3, textPadding: 8)
        #expect(inset == 131)
    }

    /// Every visible metadata column contributes its own gap - the
    /// realistic "triangle + line group + Doc" case, at the widths
    /// `setUpTableView` actually assigns.
    ///
    /// Expected value is spelled as one literal rather than the derivation
    /// `18 + 3 + 32 + 3 + 120 + 3 + 8`: as a multi-term `+` chain on the
    /// right of `#expect`, the macro reports both sides as equal and still
    /// fails the expectation.
    @Test func eachVisibleColumnContributesItsOwnIntercellGap() {
        let inset = ConcordanceViewController.overlayLeadingInset(
            visibleMetadataColumnWidths: [18, 32, 120], intercellSpacing: 3, textPadding: 8)
        #expect(inset == 187)
    }

    /// A hidden structural attribute column is filtered out by the caller
    /// before it gets here, so dropping it from the list has to move the
    /// paragraph left by exactly that column's own width plus its gap -
    /// this is what makes showing/hiding the column at runtime reposition
    /// the overlay correctly.
    @Test func droppingAColumnShiftsTheInsetLeftByThatColumnAndItsGap() {
        let withDoc = ConcordanceViewController.overlayLeadingInset(
            visibleMetadataColumnWidths: [18, 32, 120], intercellSpacing: 3, textPadding: 8)
        let withoutDoc = ConcordanceViewController.overlayLeadingInset(
            visibleMetadataColumnWidths: [18, 32], intercellSpacing: 3, textPadding: 8)
        #expect(withDoc - withoutDoc == 123)
    }

    /// Widening the structural attribute column by dragging its header
    /// moves the paragraph right by the same amount - the reason
    /// `applyOverlay` recomputes the inset on every call rather than only
    /// when the overlay is first created.
    @Test func wideningAColumnMovesTheInsetRightByTheSameAmount() {
        let narrow = ConcordanceViewController.overlayLeadingInset(visibleMetadataColumnWidths: [60])
        let wide = ConcordanceViewController.overlayLeadingInset(visibleMetadataColumnWidths: [200])
        #expect(wide - narrow == 140)
    }

    /// Fractional widths (AppKit hands these out after a uniform
    /// autoresize) must not be rounded or truncated on the way through -
    /// `17.5 + 3 + 31.25 + 3 + 8`, as one literal for the reason above.
    @Test func fractionalColumnWidthsAreCarriedThrough() {
        let inset = ConcordanceViewController.overlayLeadingInset(
            visibleMetadataColumnWidths: [17.5, 31.25], intercellSpacing: 3, textPadding: 8)
        #expect(inset == 62.75)
    }
}
