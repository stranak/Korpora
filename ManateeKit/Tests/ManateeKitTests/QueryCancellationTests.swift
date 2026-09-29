import XCTest

@testable import ManateeKit

/// Cancelling a running query (docs/project-plan.md, "Cancel a running
/// query"): cancelling the task that awaits `LiveConcordance.init` aborts the
/// engine's evaluation and throws `CancellationError`.
final class QueryCancellationTests: XCTestCase {
    private static var fixture: TestCorpusFixture!

    override class func setUp() {
        super.setUp()
        do {
            fixture = try TestCorpusFixture.build(corpusName: "mkitcancel")
        } catch {
            XCTFail("failed to build test corpus fixture: \(error)")
        }
    }

    override class func tearDown() {
        fixture?.cleanUp()
        fixture = nil
        super.tearDown()
    }

    /// A task that is already cancelled when it starts the query: the token
    /// is raised before the engine call, so the abort is deterministic.
    func testAQueryStartedByACancelledTaskThrowsCancellationError() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let task = Task { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            let live = try await LiveConcordance(corpus: corpus, cql: #"[tag="NN"]"#)
            return await live.size
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    /// Cancelling doesn't leave the corpus unusable: the next query works.
    func testTheCorpusStillWorksAfterACancelledQuery() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let cancelled = Task { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            return try await LiveConcordance(corpus: corpus, cql: #"[tag="JJ"]"#).size
        }
        cancelled.cancel()
        _ = try? await cancelled.value
        let live = try await LiveConcordance(corpus: corpus, cql: #"[tag="JJ"]"#)
        let size = await live.size
        XCTAssertEqual(size, 5)
    }

    /// Fetching the lines of a big result is the slow part of many searches
    /// (every hit is fetched), so it stops for a cancelled task too.
    func testFetchingLinesStopsForACancelledTask() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        let live = try await LiveConcordance(corpus: corpus, cql: #"[tag="NN"]"#)
        let task = Task { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            return try await live.kwicLines().count
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        // Not cancelled: the same call works.
        let lines = try await live.kwicLines()
        XCTAssertEqual(lines.count, 4)
    }

    /// A syntax error is still an ordinary error, not a cancellation.
    func testABadQueryStillThrowsItsOwnError() async throws {
        let corpus = try await Corpus(name: Self.fixture.corpusName)
        do {
            _ = try await LiveConcordance(corpus: corpus, cql: #"[tag="#)
            XCTFail("expected an error")
        } catch is CancellationError {
            XCTFail("a syntax error is not a cancellation")
        } catch {}
    }
}

/// Mid-query cancellation needs a query that takes a while, so this builds a
/// big corpus (about 10 s). Opt in with `KORPORA_SLOW_TESTS=1`.
final class QueryCancellationSlowTests: XCTestCase {
    func testCancellingAQueryInFlightStopsItEarly() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KORPORA_SLOW_TESTS"] != nil,
                          "set KORPORA_SLOW_TESTS=1 to build a large corpus")
        let tokens = 6_000_000
        var vertical = "<doc id=\"1\">\n<s>\n"
        vertical.reserveCapacity(tokens * 12)
        for i in 0..<tokens {
            vertical += (i % 3 == 0 ? "a\ta\tDT\n" : (i % 3 == 1 ? "b\tb\tJJ\n" : "c\tc\tNN\n"))
            if i % 20 == 19 { vertical += "</s>\n<s>\n" }
        }
        vertical += "</s>\n</doc>\n"
        let fixture = try TestCorpusFixture.build(corpusName: "mkitcancelslow", vertical: vertical)
        defer { fixture.cleanUp() }
        let corpus = try await Corpus(name: fixture.corpusName)

        // Every third token, then a gap of up to 40 more: plenty of hits.
        let query = #"[tag="DT"] []{0,40} [tag="NN"]"#
        let start = Date()
        let full = try await LiveConcordance(corpus: corpus, cql: query)
        let fullSeconds = Date().timeIntervalSince(start)
        let hits = await full.size
        print("SLOW full query: \(hits) hits in \(fullSeconds) s")
        try XCTSkipIf(fullSeconds < 0.5, "the full query takes \(fullSeconds) s; too fast to cancel mid-way")

        let task = Task { try await LiveConcordance(corpus: corpus, cql: query) }
        let cancelAfter = fullSeconds / 5
        try await Task.sleep(for: .seconds(cancelAfter))
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        }
        let sinceCancel = Date().timeIntervalSince(cancelledAt)
        print("SLOW cancelled after \(cancelAfter) s; returned \(sinceCancel) s later (full \(fullSeconds) s)")
        XCTAssertLessThan(sinceCancel, max(0.5, fullSeconds / 3))

        // And the corpus is fine afterwards.
        let again = try await LiveConcordance(corpus: corpus, cql: #"[tag="DT"]"#)
        let againSize = await again.size
        XCTAssertEqual(againSize, tokens / 3)
    }
}
