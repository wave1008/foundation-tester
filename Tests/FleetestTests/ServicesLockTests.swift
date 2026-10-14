import FTTestSupport
import Foundation
import XCTest
@testable import fleetest

/// 接頭辞ごとの短い排他(`services.lock/<prefix>.lock` の flock)。実行基盤には触れない。
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

    private let prefix = "fleetest-aaaaaaaaaaaa"

    private var lockFile: URL { ServicesLock.lockFile(prefix: prefix, stateDir: stateDir) }

    /// 別のプロセスが握っている状態を、別の fd の flock で作る(fd を閉じる = その持ち主が死んだ)
    private func holdRaw(pid: Int32) throws -> Int32 {
        try FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockFile.path, O_RDWR | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let data = Data(#"{"pid":\#(pid),"pidStartedAt":"2026-01-01T00:00:00Z"}"#.utf8)
        _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return fd
    }

    func testAcquireAndReleaseLeavesNoHolder() throws {
        var insideHolder: Int32?
        let value: Int = try ServicesLock.withLock(prefix: prefix, stateDir: stateDir) {
            insideHolder = ServicesLock.currentHolder(prefix: prefix, stateDir: stateDir)?.pid
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(insideHolder, ProcessInfo.processInfo.processIdentifier)
        XCTAssertNil(ServicesLock.currentHolder(prefix: prefix, stateDir: stateDir))
    }

    func testReleasesWhenTheBodyThrows() throws {
        struct Boom: Error {}
        XCTAssertThrowsError(try ServicesLock.withLock(prefix: prefix, stateDir: stateDir) { () throws -> Void in throw Boom() })
        XCTAssertNil(ServicesLock.currentHolder(prefix: prefix, stateDir: stateDir))
        var ran = false
        try ServicesLock.withLock(prefix: prefix, stateDir: stateDir, timeoutSeconds: 1, pollSeconds: 0.05) { ran = true }
        XCTAssertTrue(ran)
    }

    func testSecondAcquirerWaitsForTheFirst() throws {
        let events = LockedBox<[String]>([])
        let held = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let stateDir = self.stateDir!
        let prefix = self.prefix
        DispatchQueue.global().async {
            try? ServicesLock.withLock(prefix: prefix, stateDir: stateDir) {
                held.signal()
                Thread.sleep(forTimeInterval: 0.5)
                events.mutate { $0.append("first-release") }
            }
            finished.signal()
        }
        XCTAssertEqual(held.wait(timeout: .now() + 5), .success)
        let start = Date()
        try ServicesLock.withLock(prefix: prefix, stateDir: stateDir, pollSeconds: 0.05) {
            events.mutate { $0.append("second") }
        }
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(events.value, ["first-release", "second"])
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }

    /// 持ち主が死ぬ(fd が閉じる)とカーネルが外す。回収の処理は無く、中身に残った pid は持ち主ではない
    func testLockOfADeadOwnerIsFree() throws {
        let fd = try holdRaw(pid: 4000000)
        XCTAssertEqual(ServicesLock.currentHolder(prefix: prefix, stateDir: stateDir)?.pid, 4000000)
        close(fd)
        XCTAssertNil(ServicesLock.currentHolder(prefix: prefix, stateDir: stateDir))
        var ran = false
        try ServicesLock.withLock(prefix: prefix, stateDir: stateDir, timeoutSeconds: 1, pollSeconds: 0.05) { ran = true }
        XCTAssertTrue(ran)
    }

    func testTimesOutNamingTheHolder() throws {
        let fd = try holdRaw(pid: 4000001)
        defer { close(fd) }
        XCTAssertThrowsError(try ServicesLock.withLock(
            prefix: prefix, stateDir: stateDir, timeoutSeconds: 0.3, pollSeconds: 0.05) { }) { error in
            let text = (error as? ServicesError)?.detail ?? ""
            XCTAssertTrue(text.contains("pid 4000001"), text)
        }
        // 取れなかったロックは他人のものなので触らない(握られたまま)
        XCTAssertEqual(ServicesLock.currentHolder(prefix: prefix, stateDir: stateDir)?.pid, 4000001)
    }

    /// 2 者が同時に取りにいっても本体が重ならない(「死んだ持ち主を照合して削除」のような、他者の取得を消す窓が無い)
    func testConcurrentAcquirersNeverOverlap() throws {
        let inside = LockedBox<Int>(0)
        let maxInside = LockedBox<Int>(0)
        let done = LockedBox<Int>(0)
        let stateDir = self.stateDir!
        let prefix = self.prefix
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<10 {
                    try? ServicesLock.withLock(prefix: prefix, stateDir: stateDir, pollSeconds: 0.005) {
                        inside.mutate { $0 += 1 }
                        let seen = inside.value
                        maxInside.mutate { $0 = max($0, seen) }
                        Thread.sleep(forTimeInterval: 0.002)
                        inside.mutate { $0 -= 1 }
                        done.mutate { $0 += 1 }
                    }
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(done.value, 80)
        XCTAssertEqual(maxInside.value, 1)
    }
}
