// 掃除の錠(`RetentionSweepLock`)。**同時に2本が消さない**ことと、**持ち主が消えれば必ず外れる**
// ことの2つを固定する(外れない錠は掃除を永久に止める)。
// 置き場は一時ディレクトリ(ホーム直下の本物の錠には触らない)。

import Foundation
import XCTest
@testable import FTCore

final class RetentionSweepLockTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 先客が握っている間は2本目が取れず、先客が閉じたら取れる
    func testSecondAcquireFailsWhileHeldAndSucceedsAfterRelease() throws {
        let dir = try tempDir()
        var first: FileHandle? = RetentionSweepLock.tryAcquire(directory: dir)
        XCTAssertNotNil(first)
        XCTAssertNil(RetentionSweepLock.tryAcquire(directory: dir), "同時に2本目が取れた")
        try first?.close()
        first = nil
        XCTAssertNotNil(RetentionSweepLock.tryAcquire(directory: dir), "先客が閉じたのに取れない")
    }

    /// **別プロセスが握っている錠**も効き、そのプロセスが死ねば外れる(flock は持ち主の死で外れる)
    func testLockHeldByAnotherProcessBlocksAndIsReleasedWhenItDies() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent(RetentionSweepLock.fileName).path
        // /usr/bin/lockf は同じ flock を取ってコマンドを走らせる(macOS 標準)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        holder.arguments = ["-k", path, "/bin/sleep", "30"]
        try holder.run()
        addTeardownBlock { if holder.isRunning { holder.terminate() } }

        // 子が錠を取るまで待つ(取れなくなったら握られた)
        let deadline = Date().addingTimeInterval(5)
        var blocked = false
        while Date() < deadline {
            if let probe = RetentionSweepLock.tryAcquire(directory: dir) {
                try probe.close()
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            blocked = true
            break
        }
        XCTAssertTrue(blocked, "別プロセスが握っている錠を取れてしまった")

        holder.terminate()
        holder.waitUntilExit()
        XCTAssertNotNil(RetentionSweepLock.tryAcquire(directory: dir), "持ち主が死んだのに外れない")
    }

    /// 取った側の pid を書く(先客の名指し用)
    func testHolderPIDIsWrittenByTheAcquirer() throws {
        let dir = try tempDir()
        let lock = RetentionSweepLock.tryAcquire(directory: dir)
        XCTAssertNotNil(lock)
        XCTAssertEqual(RetentionSweepLock.holderPID(directory: dir), getpid())
        withExtendedLifetime(lock) {}
    }
}
