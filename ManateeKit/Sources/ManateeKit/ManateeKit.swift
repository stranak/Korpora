import CManatee

public enum ManateeError: Error, CustomStringConvertible {
    case failure(String)
    public var description: String {
        switch self {
        case .failure(let msg): return msg
        }
    }
}

private func consumeError(_ error: UnsafeMutablePointer<CChar>?) -> String {
    guard let error else { return "unknown error" }
    let msg = String(cString: error)
    mtc_free_string(error)
    return msg
}

public struct KWICLine: Sendable {
    public let left: String
    public let kwic: String
    public let right: String
}

/// One Manatee corpus handle plus everything derived from it. Not proven
/// thread-safe upstream, so all access is serialized through this actor
/// rather than assumed safe for concurrent queries.
public actor Corpus {
    private let handle: OpaquePointer

    public init(name: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let h = mtc_corpus_open(name, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        handle = h
    }

    deinit {
        mtc_corpus_close(handle)
    }

    public var size: Int {
        Int(mtc_corpus_size(handle))
    }

    public func query(_ cql: String, leftContext: String = "-10",
                       rightContext: String = "10", kwicAttr: String = "word") throws -> [KWICLine] {
        var error: UnsafeMutablePointer<CChar>?
        guard let conc = mtc_query(handle, cql, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_concordance_close(conc) }

        guard let kwic = mtc_kwic_open(handle, conc, leftContext, rightContext, kwicAttr, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_kwic_close(kwic) }

        var lines: [KWICLine] = []
        while mtc_kwic_next(kwic) != 0 {
            let left = mtc_kwic_get_left(kwic)
            let center = mtc_kwic_get_kwic(kwic)
            let right = mtc_kwic_get_right(kwic)
            lines.append(KWICLine(
                left: String(cString: left!),
                kwic: String(cString: center!),
                right: String(cString: right!)
            ))
            mtc_free_string(left)
            mtc_free_string(center)
            mtc_free_string(right)
        }
        return lines
    }
}
