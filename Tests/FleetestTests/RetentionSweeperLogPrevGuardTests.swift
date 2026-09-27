// ブリッジのログの「前世代」退避(`bridge-<port>.prev.log`)は、生きているブリッジの保護
// (RetentionSweeper の logs 系統の guarded 判定)に巻き込まれないことを確かめる。
//
// `.prev.log` の書き出し自体は別の担当者の変更(ログの上書き前に直前の1世代を退避する)。
// ここは `bridgeLogIsLive`(private)の入口 `sessions(for: .logs, roots:, activeRunID:)` を通して、
// 命名の走査(`bridge-` プレフィックス + ポート番号の直後に拡張子)が `.prev.log` まで
// 「生きている」扱いにしないことだけを固定する —— 現行ログ(`bridge-<port>.log`)は
// そのポートが生きていれば守られ、前世代は古い世代として消せる。

import FTCore
import XCTest
@testable import fleetest

final class RetentionSweeperLogPrevGuardTests: XCTestCase {
    private var toolRoot: URL!

    override func setUpWithError() throws {
        toolRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-logs-prev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: toolRoot.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: toolRoot)
    }

    private func writePid(_ pid: Int32, port: UInt16) throws {
        try String(pid).write(
            to: toolRoot.appendingPathComponent(".fleetest/bridge-\(port).pid"),
            atomically: true, encoding: .utf8)
    }

    /// **modified を明示指定**(同着だと plan の並びで意図と違う側が消えうる。
    /// RetentionSweeperXcresultTests / DumpRetentionTests と同じ方式)
    private func writeLog(_ name: String, bytes: Int = 10, modified: Date? = nil) throws {
        let url = toolRoot.appendingPathComponent(".fleetest/\(name)")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func roots() -> RetentionSweeper.Roots {
        RetentionSweeper.Roots(package: toolRoot, tool: toolRoot)
    }

    /// 前世代の退避(`.prev.log`)は、そのポートのブリッジが生きていても保護されない
    /// (消してよい)。現行ログ(`bridge-<port>.log`)は同じポートで生きていれば保護される
    func testPrevGenerationLogIsNotGuardedEvenWhenTheLivePortIsGuarded() throws {
        let live = Process()
        live.executableURL = URL(fileURLWithPath: "/bin/sleep")
        live.arguments = ["30"]
        try live.run()
        defer { live.terminate(); live.waitUntilExit() }
        try writePid(live.processIdentifier, port: 8140)
        try writeLog("bridge-8140.log")
        try writeLog("bridge-8140.prev.log")

        let sessions = RetentionSweeper.sessions(for: .logs, roots: roots(), activeRunID: nil)
        let current = try XCTUnwrap(sessions.first { $0.paths.first?.lastPathComponent == "bridge-8140.log" })
        let prev = try XCTUnwrap(sessions.first { $0.paths.first?.lastPathComponent == "bridge-8140.prev.log" })
        XCTAssertTrue(current.guarded, "生きているポートの現行ログは守る")
        XCTAssertFalse(prev.guarded, "前世代の退避は古い世代なので消してよい")
    }

    /// clean() の統合: 上限超過時、前世代の退避は消え、生きているポートの現行ログは残る
    func testCleanDeletesThePrevGenerationButKeepsTheLiveCurrentLog() throws {
        let live = Process()
        live.executableURL = URL(fileURLWithPath: "/bin/sleep")
        live.arguments = ["30"]
        try live.run()
        defer { live.terminate(); live.waitUntilExit() }
        try writePid(live.processIdentifier, port: 8141)
        // 前世代は古い世代(実運用でも上書き前の分なので現行より古い)
        try writeLog("bridge-8141.prev.log", bytes: 6 * 1_048_576,
                     modified: Date().addingTimeInterval(-3600))
        try writeLog("bridge-8141.log", bytes: 6 * 1_048_576)

        let report = RetentionSweeper.clean(
            roots: roots(), categories: [.logs],
            policy: RetentionPolicy(logsMaxBytes: 10 * 1_048_576),  // 10 MiB cap
            dryRun: false, log: { _ in }, notice: { _ in })

        XCTAssertEqual(report.categories.first?.deletedSessions, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: toolRoot.appendingPathComponent(".fleetest/bridge-8141.prev.log").path),
            "前世代は消える")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: toolRoot.appendingPathComponent(".fleetest/bridge-8141.log").path),
            "生きているポートの現行ログは残る")
    }
}
