// xcresult(XCUITest ランナーの結果の束)の保持容量掃除。
//
// **guarded の判定は生死(`ProcessLiveness.isAlive`)だけ**(pid ファイルの存在ではない)ことと、
// 名前がブリッジの束の形でない束には触らないことを、実プロセス(/bin/sleep)を立てて確かめる
// (BridgeLauncherStopTests / RetentionSweeperRootsTests と同じ方式)。
//
// **必ず別の一時フォルダで行う**(保守者のクローン構成では `.fleetest/xcresult/` に実データが
// あるので、手元の実データでは取り違えが出ない。docs/results-json.md §保持容量)。

import FTCore
import XCTest
@testable import fleetest

final class RetentionSweeperXcresultTests: XCTestCase {
    private var toolRoot: URL!

    override func setUpWithError() throws {
        toolRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-xcresult-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: toolRoot.appendingPathComponent(".fleetest/xcresult"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: toolRoot)
    }

    /// **`modified` は同着を避けるための明示指定**(plan は新しい順に積むので、2セッションが
    /// 同じ mtime だとテストの意図と違う側が消える恐れがある。DumpRetentionTests と同じ方式)
    @discardableResult
    private func writeBundle(_ name: String, bytes: Int, modified: Date? = nil) throws -> URL {
        let dir = toolRoot.appendingPathComponent(".fleetest/xcresult/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Session.log")
        try Data(repeating: 0x41, count: bytes).write(to: file)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: dir.path)
        }
        return dir
    }

    private func writePid(_ pid: Int32, port: UInt16) throws {
        try String(pid).write(
            to: toolRoot.appendingPathComponent(".fleetest/bridge-\(port).pid"),
            atomically: true, encoding: .utf8)
    }

    private func roots() -> RetentionSweeper.Roots {
        RetentionSweeper.Roots(package: toolRoot, tool: toolRoot)
    }

    // MARK: - guarded 判定

    func testLiveBridgePortIsGuarded() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        defer { proc.terminate(); proc.waitUntilExit() }
        try writePid(proc.processIdentifier, port: 8128)
        try writeBundle("bridge-8128-111.xcresult", bytes: 100)

        let sessions = RetentionSweeper.sessions(for: .xcresult, roots: roots(), activeRunID: nil)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].guarded, "生きているブリッジの束は消さない")
    }

    /// **生死は pid ファイルの存在ではなくプロセスの実体で見る** —— 掃除し忘れた pid ファイルが
    /// guarded を永久に固定しないため(BridgeLauncherStopTests と同じ規律)
    func testDeadBridgePortIsNotGuarded() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["0"]
        try proc.run()
        proc.waitUntilExit()  // 既に終了・reap 済み
        try writePid(proc.processIdentifier, port: 8129)
        try writeBundle("bridge-8129-222.xcresult", bytes: 100)

        let sessions = RetentionSweeper.sessions(for: .xcresult, roots: roots(), activeRunID: nil)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(sessions[0].guarded, "生きていないブリッジ(孤児)の束は消してよい")
    }

    func testMissingPidFileIsNotGuarded() throws {
        try writeBundle("bridge-8130-333.xcresult", bytes: 100)
        let sessions = RetentionSweeper.sessions(for: .xcresult, roots: roots(), activeRunID: nil)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(sessions[0].guarded)
    }

    /// ブリッジの束の命名(`bridge-<port>[-<stamp>].xcresult`)でない物には触らない
    /// (利用者やほかのツールが置いた物かもしれない)
    func testUnrecognizedNamesAreIgnored() throws {
        try writeBundle("not-a-bridge-bundle.xcresult", bytes: 100)
        try writeBundle("bridge-not-a-port.xcresult", bytes: 100)
        let sessions = RetentionSweeper.sessions(for: .xcresult, roots: roots(), activeRunID: nil)
        XCTAssertTrue(sessions.isEmpty, "触れない形の名前は対象外")
    }

    // MARK: - clean() との統合

    /// 孤児(生きていないポート)は上限超過で消え、生きているポートの束は残る。
    /// **孤児を古い側に置く**(plan は新しい順に積んで超過分を落とすので、新しい側に置くと
    /// guarded ではない生きているブリッジの束のほうが先に消える対象になってしまい、
    /// テストの意図(guarded は絶対に消えない)を確かめられない)
    func testCleanDeletesOrphanedBundlesButKeepsLiveOnes() throws {
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/bin/sleep")
        dead.arguments = ["0"]
        try dead.run()
        dead.waitUntilExit()
        try writePid(dead.processIdentifier, port: 8132)
        try writeBundle("bridge-8132-2.xcresult", bytes: 6 * 1_048_576,  // 6 MiB, orphan, older
                        modified: Date().addingTimeInterval(-3600))

        let live = Process()
        live.executableURL = URL(fileURLWithPath: "/bin/sleep")
        live.arguments = ["30"]
        try live.run()
        defer { live.terminate(); live.waitUntilExit() }
        try writePid(live.processIdentifier, port: 8131)
        try writeBundle("bridge-8131-1.xcresult", bytes: 6 * 1_048_576)  // 6 MiB, live, newer (now)

        var notices: [String] = []
        let report = RetentionSweeper.clean(
            roots: roots(), categories: [.xcresult],
            policy: RetentionPolicy(xcresultMaxBytes: 10 * 1_048_576),  // 10 MiB cap
            dryRun: false, log: { _ in }, notice: { notices.append($0) })

        XCTAssertEqual(report.categories.first?.deletedSessions, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: toolRoot.appendingPathComponent(".fleetest/xcresult/bridge-8132-2.xcresult").path),
            "孤児は消える")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: toolRoot.appendingPathComponent(".fleetest/xcresult/bridge-8131-1.xcresult").path),
            "生きているブリッジの束は残る")
        XCTAssertTrue(notices.isEmpty, "guarded だけでは上限を超えていない")
    }

    /// guarded だけで上限を超えたら、掃除できなくても事実を通知する(消しはしない)
    func testNoticeFiresWhenLiveBundlesAloneExceedTheCapAndNothingIsDeleted() throws {
        let live = Process()
        live.executableURL = URL(fileURLWithPath: "/bin/sleep")
        live.arguments = ["30"]
        try live.run()
        defer { live.terminate(); live.waitUntilExit() }
        try writePid(live.processIdentifier, port: 8133)
        try writeBundle("bridge-8133-1.xcresult", bytes: 6 * 1_048_576)

        var notices: [String] = []
        let report = RetentionSweeper.clean(
            roots: roots(), categories: [.xcresult],
            policy: RetentionPolicy(xcresultMaxBytes: 1024),  // 生きているだけで超える上限
            dryRun: false, log: { _ in }, notice: { notices.append($0) })

        XCTAssertEqual(report.categories.first?.overCapAfterGuards, true)
        XCTAssertFalse(notices.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: toolRoot.appendingPathComponent(".fleetest/xcresult/bridge-8133-1.xcresult").path),
            "生きているので消えない")
    }
}
