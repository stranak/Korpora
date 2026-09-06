import XCTest

@testable import ManateeKit

final class CorpusMemoryResidencyTests: XCTestCase {
    func testCanKeepResidentRequiresThresholdAfterSubtraction() {
        XCTAssertTrue(CorpusMemoryResidency.canKeepResident(
            sizeBytes: 10_000, currentlyAvailable: 20_000, minimumFreeAfter: 5_000))
        XCTAssertFalse(CorpusMemoryResidency.canKeepResident(
            sizeBytes: 10_000, currentlyAvailable: 14_000, minimumFreeAfter: 5_000))
        XCTAssertTrue(CorpusMemoryResidency.canKeepResident(
            sizeBytes: 10_000, currentlyAvailable: 15_000, minimumFreeAfter: 5_000))
    }

    func testDirectorySizeSumsFilesRecursively() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ResidencySizeTests-\(UUID().uuidString)")
        let subDir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try Data(repeating: 0, count: 100).write(to: tempDir.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 250).write(to: subDir.appendingPathComponent("b.bin"))

        XCTAssertEqual(CorpusMemoryResidency.directorySize(tempDir), 350)
    }

    func testWarmAndUnwarmDoNotThrowForRealFiles() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ResidencyWarmTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try Data(repeating: 1, count: 4096).write(to: tempDir.appendingPathComponent("a.bin"))

        try await CorpusMemoryResidency.warm(directory: tempDir)
        CorpusMemoryResidency.unwarm(directory: tempDir)
    }

    func testAvailableMemoryIsPositiveAndBelowTotal() {
        let available = CorpusMemoryResidency.availableMemory()
        XCTAssertGreaterThan(available, 0)
        XCTAssertLessThanOrEqual(available, CorpusMemoryResidency.totalMemory)
    }
}
