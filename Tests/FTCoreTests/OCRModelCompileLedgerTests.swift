import XCTest
@testable import FTCore

final class OCRModelCompileLedgerTests: XCTestCase {
    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocr-compile-\(UUID().uuidString)", isDirectory: true)
    }

    func testMissingDirectoryCountsZero() {
        XCTAssertEqual(OCRModelCompileLedger.activeCount(in: tempDir()), 0)
    }

    func testMarkAndUnmarkOwnPid() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pid = ProcessInfo.processInfo.processIdentifier
        OCRModelCompileLedger.markPresent(in: dir, pid: pid)
        XCTAssertEqual(OCRModelCompileLedger.activeCount(in: dir, now: Date().addingTimeInterval(2)), 1)
        OCRModelCompileLedger.markAbsent(in: dir, pid: pid)
        XCTAssertEqual(OCRModelCompileLedger.activeCount(in: dir, now: Date().addingTimeInterval(2)), 0)
    }

    func testDeadPidIsNotCountedAndIsReaped() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deadPid: Int32 = 99999
        try XCTSkipIf(ProcessLiveness.isAlive(deadPid), "pid \(deadPid) is alive on this machine")
        OCRModelCompileLedger.markPresent(in: dir, pid: deadPid)
        XCTAssertEqual(OCRModelCompileLedger.activeCount(in: dir, now: Date().addingTimeInterval(2)), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("99999").path))
    }

    /// 置かれたばかりの印は数えない(コンパイル済み機械の 0.2〜0.3 秒の探りで帯がちらつかないため)
    func testFreshMarkIsNotCountedUntilItIsOldEnough() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        OCRModelCompileLedger.markPresent(in: dir, pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(OCRModelCompileLedger.activeCount(in: dir, now: Date()), 0)
        XCTAssertEqual(OCRModelCompileLedger.activeCount(in: dir, now: Date().addingTimeInterval(1.5)), 1)
    }

    func testMinimumAgeIsPinned() {
        XCTAssertEqual(OCRModelCompileLedger.minimumAge, 1.0)
    }
}
