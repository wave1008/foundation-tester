// SimulatorBootCleanup: 統合ログの Special は新しい N 個だけ残す・.tracev3 以外には触れない。

import XCTest
@testable import FTBridgeClient

final class SimulatorBootCleanupTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("special-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ name: String) throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }

    private func remaining() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func testKeepsTheNewestFilesByNameAndLeavesOtherFilesAlone() throws {
        for i in 1...5 { try touch(String(format: "%016x.tracev3", i)) }
        try touch("notes.txt")

        let removed = SimulatorBootCleanup.trimSpecialLogs(in: dir, keep: 2)

        XCTAssertEqual(removed, 3)
        XCTAssertEqual(try remaining(), ["0000000000000004.tracev3", "0000000000000005.tracev3", "notes.txt"])
    }

    func testNothingToDoWhenAtOrBelowTheLimit() throws {
        for i in 1...2 { try touch(String(format: "%016x.tracev3", i)) }
        XCTAssertEqual(SimulatorBootCleanup.trimSpecialLogs(in: dir, keep: 2), 0)
        XCTAssertEqual(try remaining().count, 2)
    }

    func testMissingDirectoryIsANoOp() {
        XCTAssertEqual(SimulatorBootCleanup.trimSpecialLogs(in: dir.appendingPathComponent("absent"), keep: 1), 0)
    }

    func testDefaultKeepIsPinned() {
        XCTAssertEqual(SimulatorBootCleanup.specialLogFilesToKeep, 100)
    }
}
