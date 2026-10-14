import FTTestSupport
import Foundation
import XCTest
@testable import fleetest

/// 接頭辞ごとの短い排他(`services.lock/<prefix>/`)。実行基盤には触れない。
final class ServicesLockTests: XCTestCase {

    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("services-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private var lockDir: URL {
        stateDir.appendingPathComponent("services.lock").appendingPathComponent("fleetest-aaaaaaaaaaaa")
    }

    func testAcquireAndReleaseLeavesNoDirectory() throws {
        var insideExists = false
        let value: Int = try ServicesLock.withLock(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir) {
            insideExists = FileManager.default.fileExists(atPath: lockDir.path)
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertTrue(insideExists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path))
    }

    func testReleasesWhenTheBodyThrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(try ServicesLock.withLock(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir) { () throws -> Void in throw Boom() })
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path))
    }

    func testSecondAcquirerWaitsForTheFirst() throws {
        let events = LockedBox<[String]>([])
        let held = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let stateDir = self.stateDir!
        DispatchQueue.global().async {
            try? ServicesLock.withLock(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir) {
                held.signal()
                Thread.sleep(forTimeInterval: 0.5)
                events.mutate { $0.append("first-release") }
            }
            finished.signal()
        }
        XCTAssertEqual(held.wait(timeout: .now() + 5), .success)
        let start = Date()
        try ServicesLock.withLock(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir, pollSeconds: 0.05) {
            events.mutate { $0.append("second") }
        }
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(events.value, ["first-release", "second"])
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }

    func testLockOfADeadOwnerIsReclaimed() throws {
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        // pid_max(macOS は 99998)を超える pid は存在しない
        try Data(#"{"pid":4000000,"pidStartedAt":"2026-01-01T00:00:00Z"}"#.utf8)
            .write(to: lockDir.appendingPathComponent("owner"))
        var ran = false
        try ServicesLock.withLock(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir, pollSeconds: 0.05) { ran = true }
        XCTAssertTrue(ran)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path))
    }

    func testTimesOutNamingTheHolder() throws {
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        try Data(#"{"pid":4000001,"pidStartedAt":"2026-01-01T00:00:00Z"}"#.utf8)
            .write(to: lockDir.appendingPathComponent("owner"))
        XCTAssertThrowsError(try ServicesLock.withLock(
            prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir, timeoutSeconds: 0.3, pollSeconds: 0.05,
            isAlive: { _, _ in true }) { }) { error in
            let text = (error as? ServicesError)?.detail ?? ""
            XCTAssertTrue(text.contains("pid 4000001"), text)
        }
        // 取れなかったロックは他人のものなので消さない
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockDir.path))
    }

    func testCurrentHolderAndForceRelease() throws {
        XCTAssertNil(ServicesLock.currentHolder(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir))
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        try Data(#"{"pid":4000002,"pidStartedAt":"2026-01-01T00:00:00Z"}"#.utf8)
            .write(to: lockDir.appendingPathComponent("owner"))
        XCTAssertEqual(ServicesLock.currentHolder(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir)?.pid, 4000002)
        // 押し切った後の解放は、押し切るときに見た持ち主のままのときだけ(取り直した別の持ち主のロックは消さない)
        ServicesLock.forceRelease(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir, ifHeldBy: (4000003, "2026-01-01T00:00:00Z"))
        XCTAssertEqual(ServicesLock.currentHolder(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir)?.pid, 4000002)
        ServicesLock.forceRelease(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir, ifHeldBy: (4000002, "2026-01-01T00:00:01Z"))
        XCTAssertEqual(ServicesLock.currentHolder(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir)?.pid, 4000002)
        ServicesLock.forceRelease(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir, ifHeldBy: (4000002, "2026-01-01T00:00:00Z"))
        XCTAssertNil(ServicesLock.currentHolder(prefix: "fleetest-aaaaaaaaaaaa", stateDir: stateDir))
    }
}
