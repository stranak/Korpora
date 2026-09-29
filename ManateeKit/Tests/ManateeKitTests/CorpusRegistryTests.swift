import XCTest

@testable import ManateeKit

final class CorpusRegistryTests: XCTestCase {
    private var directory: URL!
    private var savedRegistry: String?

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CorpusRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedRegistry = ProcessInfo.processInfo.environment["MANATEE_REGISTRY"]
        setenv("MANATEE_REGISTRY", directory.path, 1)
    }

    override func tearDownWithError() throws {
        if let savedRegistry { setenv("MANATEE_REGISTRY", savedRegistry, 1) } else { unsetenv("MANATEE_REGISTRY") }
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String) throws {
        try "NAME \"\(name)\"\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testListsRegistryFilesSorted() throws {
        try write("zeta")
        try write("alpha")
        XCTAssertEqual(CorpusRegistry.availableCorpusNames(), ["alpha", "zeta"])
    }

    /// Finder leaves a `.DS_Store` in folders it has opened; it isn't a corpus.
    func testHiddenFilesAreNotCorpora() throws {
        try write("alpha")
        try write(".DS_Store")
        try write(".hidden")
        XCTAssertEqual(CorpusRegistry.availableCorpusNames(), ["alpha"])
    }

    func testSubdirectoriesAreNotCorpora() throws {
        try write("alpha")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("alpha.data"), withIntermediateDirectories: true)
        XCTAssertEqual(CorpusRegistry.availableCorpusNames(), ["alpha"])
    }
}
