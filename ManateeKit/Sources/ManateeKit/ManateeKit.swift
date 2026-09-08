import CManatee
import Foundation

public enum ManateeError: Error, CustomStringConvertible {
    case failure(String)
    public var description: String {
        switch self {
        case .failure(let msg): return msg
        }
    }
}

func consumeError(_ error: UnsafeMutablePointer<CChar>?) -> String {
    guard let error else { return "unknown error" }
    let msg = String(cString: error)
    mtc_free_string(error)
    return msg
}

/// One token's positional-attribute values within a `KWICLine`. `word` is
/// whichever attribute `LiveConcordance.kwicLines` was called with as its
/// primary `kwicAttr` (default "word"); `secondaryAttributes` holds any
/// additional attributes requested via `kwicLines(secondaryAttributes:)`
/// (e.g. "lemma"/"tag"), keyed by attribute name - empty when none were
/// requested.
public struct KWICToken: Sendable, Equatable {
    public let word: String
    public let secondaryAttributes: [String: String]

    public init(word: String, secondaryAttributes: [String: String]) {
        self.word = word
        self.secondaryAttributes = secondaryAttributes
    }
}

public struct KWICLine: Sendable {
    public let leftTokens: [KWICToken]
    public let kwicTokens: [KWICToken]
    public let rightTokens: [KWICToken]
    /// The match's corpus-wide token start position - stable and meaningful
    /// independent of the `LiveConcordance`/iterator that produced this
    /// line, so a caller can look up this specific hit's enclosing
    /// structural attributes (e.g. "doc.author") later, on demand, via
    /// `Corpus.structuralAttributeValue(at:attribute:)`, without keeping
    /// anything else alive.
    public let position: Int

    /// Plain space-joined display text, for callers that don't need
    /// per-token/secondary-attribute detail - the whole `KWICLine` API
    /// before secondary attributes existed.
    public var left: String { Self.joined(leftTokens) }
    public var kwic: String { Self.joined(kwicTokens) }
    public var right: String { Self.joined(rightTokens) }

    public init(leftTokens: [KWICToken], kwicTokens: [KWICToken], rightTokens: [KWICToken], position: Int) {
        self.leftTokens = leftTokens
        self.kwicTokens = kwicTokens
        self.rightTokens = rightTokens
        self.position = position
    }

    private static func joined(_ tokens: [KWICToken]) -> String {
        tokens.map(\.word).joined(separator: " ")
    }
}

/// One Manatee corpus handle plus everything derived from it. Not proven
/// thread-safe upstream, so all access is serialized through this actor
/// rather than assumed safe for concurrent queries.
public actor Corpus {
    /// The name (or subcorpus path) this handle was opened with - kept
    /// around for `createSubcorpus`'s own directory naming and so a
    /// subcorpus `Corpus` can still report the corpus it belongs to.
    public let name: String

    // Module-internal (not private) so `LiveConcordance` can open a query
    // against this corpus without re-exposing the raw handle publicly.
    // `nonisolated(unsafe)` because it's an immutable raw pointer value -
    // copying it across actor isolation is fine; it's the engine calls that
    // *use* it that need serializing, and those stay actor-isolated (here
    // and in `LiveConcordance`) regardless of how this property is
    // annotated. Without this, Swift 6 mode treats reading it from another
    // actor as an error (non-Sendable type exiting actor isolation).
    nonisolated(unsafe) let handle: OpaquePointer

    public init(name: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let h = mtc_corpus_open(name, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        self.name = name
        handle = h
    }

    /// Wraps an already-open handle (e.g. a subcorpus - see `openSubcorpus`)
    /// without going through Manatee's own name-based registry lookup again.
    fileprivate init(wrapping handle: OpaquePointer, name: String) {
        self.handle = handle
        self.name = name
    }

    deinit {
        mtc_corpus_close(handle)
    }

    /// Token count - for a subcorpus (see `openSubcorpus`), this is the
    /// subcorpus's own restricted size, not the parent corpus's full size.
    ///
    /// Throwing despite reading like a plain accessor: this is the first call
    /// that touches the corpus's *compiled data* rather than its registry
    /// file, so it's where a corpus that opened perfectly well turns out to
    /// be unreadable - a registry `PATH` is an absolute path, and it may no
    /// longer resolve (a moved directory, an unmounted volume, a deleted
    /// `.data` sibling). See `mtc_corpus_size`'s own doc comment.
    public var size: Int {
        get throws {
            var error: UnsafeMutablePointer<CChar>?
            let size = mtc_corpus_size(handle, &error)
            guard size >= 0 else {
                throw ManateeError.failure(consumeError(error))
            }
            return Int(size)
        }
    }

    /// One-shot convenience over `LiveConcordance` for callers that just want
    /// a single query's KWIC lines and don't need to sort/filter/shuffle/
    /// sample it afterward.
    public func query(_ cql: String, leftContext: String = "-10",
                       rightContext: String = "10", kwicAttr: String = "word") async throws -> [KWICLine] {
        let live = try await LiveConcordance(corpus: self, cql: cql)
        return try await live.kwicLines(leftContext: leftContext, rightContext: rightContext, kwicAttr: kwicAttr)
    }

    /// The registry metadata parsed when this corpus was opened - positional
    /// attributes and structures/structural-attributes, for building a
    /// corpus browser or a CQL-writing aid.
    ///
    /// The attribute/structure walk itself is cheap (no engine work, just the
    /// already-parsed `CorpInfo` tree - see `mtcbridge.cc`), but `sizeTokens`
    /// comes from `size`, which does open compiled data off disk and can
    /// therefore fail. That mismatch used to be masked: `info()` was
    /// non-throwing and this comment claimed the whole call did no engine
    /// work, so a corpus with an unresolvable registry `PATH` aborted the
    /// process from inside a getter instead of surfacing an error.
    public func info() throws -> CorpusInfo {
        var attributes: [String] = []
        for i in 0..<mtc_corpus_attr_count(handle) {
            guard let cstr = mtc_corpus_attr_name(handle, i) else { continue }
            attributes.append(String(cString: cstr))
            mtc_free_string(cstr)
        }

        var structures: [StructureInfo] = []
        for i in 0..<mtc_corpus_struct_count(handle) {
            guard let structCStr = mtc_corpus_struct_name(handle, i) else { continue }
            let structName = String(cString: structCStr)
            mtc_free_string(structCStr)

            var structAttributes: [String] = []
            for j in 0..<mtc_corpus_struct_attr_count(handle, structName) {
                guard let attrCStr = mtc_corpus_struct_attr_name(handle, structName, j) else { continue }
                structAttributes.append(String(cString: attrCStr))
                mtc_free_string(attrCStr)
            }
            structures.append(StructureInfo(name: structName, attributes: structAttributes))
        }

        return CorpusInfo(name: name, sizeTokens: try size, attributes: attributes, structures: structures)
    }

    /// Creates a subcorpus restricted to `query`'s hits within `structure`
    /// (e.g. one `<doc>`) and saves it under `SubcorpusStore`, returning its
    /// path. Manatee subcorpora are always disk-backed - there's no
    /// in-memory-only form (see `mtc_create_subcorpus`'s doc comment).
    public func createSubcorpus(named subcorpusName: String, structure: String, query: String) throws -> String {
        let directory = SubcorpusStore.directory(for: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = SubcorpusStore.path(for: name, subcorpusName: subcorpusName)
        var error: UnsafeMutablePointer<CChar>?
        guard mtc_create_subcorpus(handle, path, structure, query, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
        return path
    }

    /// The value of structural attribute `attribute` (e.g. "doc.author") for
    /// whichever structure instance encloses `position` - a real per-match
    /// lookup (see `mtc_corpus_get_struct_attr`'s doc comment), not the
    /// registry-only names `info()` returns. `position` normally comes from
    /// a `KWICLine.position` obtained earlier from this same corpus (or an
    /// equivalent one - a subcorpus/its parent share the same underlying
    /// token positions). Empty string if `position` isn't enclosed by any
    /// instance of that structure.
    public func structuralAttributeValue(at position: Int, attribute: String) throws -> String {
        var error: UnsafeMutablePointer<CChar>?
        guard let cstr = mtc_corpus_get_struct_attr(handle, Int64(position), attribute, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_free_string(cstr) }
        return String(cString: cstr)
    }

    /// Space-joined values of positional attribute `attribute` (e.g.
    /// "word") over corpus-wide token positions `[fromPosition,
    /// toPosition)` - "Extended Context"'s primitive (Phase 6.6): given a
    /// hit's own position (`KWICLine.position`) and match length, the
    /// caller asks for a much wider window around it directly, with no
    /// live query/concordance needed at all - see
    /// `mtc_corpus_positional_attr_range`'s own doc comment. Silently
    /// clamped to the corpus's own bounds by the bridge - a hit near the
    /// very start/end of the corpus is expected to ask for a range that
    /// runs off one side.
    public func positionalAttributeRange(from fromPosition: Int, to toPosition: Int, attribute: String) throws -> String {
        var error: UnsafeMutablePointer<CChar>?
        guard let cstr = mtc_corpus_positional_attr_range(handle, Int64(fromPosition), Int64(toPosition), attribute, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_free_string(cstr) }
        return String(cString: cstr)
    }

    /// Opens a previously created subcorpus (see `createSubcorpus`) as its
    /// own `Corpus` - queries against it are automatically restricted to the
    /// subcorpus's range, since `SubCorpus` overrides `filter_query` in C++
    /// and every existing shim call (`mtc_query`, sort/filter/etc.) already
    /// goes through that virtually, unchanged.
    public func openSubcorpus(atPath path: String) throws -> Corpus {
        var error: UnsafeMutablePointer<CChar>?
        guard let h = mtc_subcorpus_open(handle, path, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        return Corpus(wrapping: h, name: name)
    }
}

public struct StructureInfo: Sendable {
    public let name: String
    public let attributes: [String]
}

public struct CorpusInfo: Sendable {
    public let name: String
    public let sizeTokens: Int
    public let attributes: [String]
    public let structures: [StructureInfo]
}
