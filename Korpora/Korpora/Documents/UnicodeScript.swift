import Foundation

/// A coarse Unicode script classification, for picking a per-script
/// concordance font override (Phase 6.5) when one font's glyph coverage
/// isn't ideal for every script a corpus's text might contain (a
/// multilingual corpus, or loanwords/citations in a different script).
/// Deliberately dependency-free (plain code-point ranges, not ICU/CoreText
/// script detection) - covers the scripts most likely to actually show up
/// in a corpus-linguistics tool; anything else falls into `.other`.
enum UnicodeScript: String, CaseIterable {
    case latin
    case cyrillic
    case greek
    case hebrew
    case arabic
    case cjk
    case other

    var displayName: String {
        switch self {
        case .latin: return "Latin"
        case .cyrillic: return "Cyrillic"
        case .greek: return "Greek"
        case .hebrew: return "Hebrew"
        case .arabic: return "Arabic"
        case .cjk: return "CJK"
        case .other: return "Other"
        }
    }

    /// `token`'s dominant script - its first scalar that resolves to a
    /// non-`.other` script, or `.other` if none do (e.g. a token made
    /// entirely of digits/punctuation, or a single inter-token space).
    /// Per-token granularity, not per-character - a token mixing scripts
    /// (rare) is classified by whichever comes first.
    static func dominant(in token: String) -> UnicodeScript {
        for scalar in token.unicodeScalars {
            let script = classify(scalar)
            if script != .other { return script }
        }
        return .other
    }

    private static func classify(_ scalar: Unicode.Scalar) -> UnicodeScript {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
            return .latin
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0400...0x04FF, 0x0500...0x052F:
            return .cyrillic
        case 0x0590...0x05FF:
            return .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F:
            return .arabic
        case 0x3040...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7AF:
            return .cjk
        default:
            return .other
        }
    }
}
