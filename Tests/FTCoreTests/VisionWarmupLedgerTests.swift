import XCTest
@testable import FTCore

final class VisionWarmupLedgerTests: XCTestCase {
    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vision-warmup-\(UUID().uuidString)", isDirectory: true)
    }

    func testMissingDirectoryCountsZero() {
        XCTAssertEqual(VisionWarmupLedger.activeCount(in: tempDir()), 0)
    }

    func testMarkAndUnmarkOwnPid() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pid = ProcessInfo.processInfo.processIdentifier
        VisionWarmupLedger.markPresent(in: dir, pid: pid)
        XCTAssertEqual(VisionWarmupLedger.activeCount(in: dir, now: Date().addingTimeInterval(2)), 1)
        VisionWarmupLedger.markAbsent(in: dir, pid: pid)
        XCTAssertEqual(VisionWarmupLedger.activeCount(in: dir, now: Date().addingTimeInterval(2)), 0)
    }

    func testDeadPidIsNotCountedAndIsReaped() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deadPid: Int32 = 99999
        try XCTSkipIf(ProcessLiveness.isAlive(deadPid), "pid \(deadPid) is alive on this machine")
        VisionWarmupLedger.markPresent(in: dir, pid: deadPid)
        XCTAssertEqual(VisionWarmupLedger.activeCount(in: dir, now: Date().addingTimeInterval(2)), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("99999").path))
    }

    /// 置かれたばかりの印は数えない(暖まっている機械の 0.2〜0.3 秒の探りで帯がちらつかないため)
    func testFreshMarkIsNotCountedUntilItIsOldEnough() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        VisionWarmupLedger.markPresent(in: dir, pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(VisionWarmupLedger.activeCount(in: dir, now: Date()), 0)
        XCTAssertEqual(VisionWarmupLedger.activeCount(in: dir, now: Date().addingTimeInterval(1.5)), 1)
    }

    func testMinimumAgeIsPinned() {
        XCTAssertEqual(VisionWarmupLedger.minimumAge, 1.0)
    }
}
