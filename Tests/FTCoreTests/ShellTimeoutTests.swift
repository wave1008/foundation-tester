import Foundation
import XCTest
@testable import FTCore

final class ShellTimeoutTests: XCTestCase {

    /// wedge した子(`sleep 30`)を timeout で kill し、締切近辺で ShellError.timedOut を投げる。
    /// これが機能しないと 30s 丸ごとブロックする(= adb/simctl の wedge で device-up が永久ハングする回帰)。
    func testTimeoutKillsWedgedChild() {
        let start = Date()
        XCTAssertThrowsError(try Shell.run(["sleep", "30"], timeout: 0.5)) { error in
            guard case ShellError.timedOut(_, let seconds) = error else {
                return XCTFail("期待: ShellError.timedOut / 実際: \(error)")
            }
            XCTAssertEqual(seconds, 0.5, accuracy: 0.001)
        }
        // 0.5s の締切 + SIGTERM 即応で概ね即死。30s 待ちに戻る回帰を検出するため十分小さい上限で締める。
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0, "timeout 後も長時間ブロックしている")
    }

    /// timeout 内に終わる通常コマンドは kill されず出力と exit code を通常どおり返す。
    func testFastCommandCompletesWithinTimeout() throws {
        let result = try Shell.run(["echo", "hello-fleetest"], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello-fleetest")
    }

    /// 非ゼロ exit code も timeout 経路で正しく伝播する(タイムアウトと誤検出しない)。
    func testNonZeroExitPropagatesWithoutTimeout() throws {
        let result = try Shell.run(["false"], timeout: 10)
        XCTAssertNotEqual(result.status, 0)
    }

    /// **SIGTERM を無視する孫が stdout を継承したまま残っても timeout で返る**(Codex 指摘 2026-09-05)。
    /// `terminate()` はグループへ SIGTERM を送るが、`trap '' TERM` を継いだ孫は死なず、
    /// 2 秒後の SIGKILL は直接の子にしか届かないので、孫がパイプの書込端を握り続け EOF 待ちで
    /// 30 秒返らなかった(実測)。子孫ごと SIGKILL することと、出力回収に期限があることの両方が要る
    func testTimeoutReturnsEvenWhenAGrandchildHoldsStdout() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-shell-grandchild-\(getpid()).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let start = Date()
        XCTAssertThrowsError(try Shell.run(
            ["sh", "-c", "trap '' TERM; sleep 30 & echo $! > '\(pidFile.path)'; sleep 30"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0,
                          "孫が stdout を握ったまま timeout 後も返らない")
        // **孫も死んでいる**(グループごと SIGKILL)。直接の子だけ殺す実装だと孫の sleep が残る
        let grandchild = Int32((try String(contentsOf: pidFile, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(grandchild, 0, "孫の pid が取れない")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, kill(grandchild, 0) == 0 { usleep(50_000) }
        XCTAssertNotEqual(kill(grandchild, 0), 0, "孫(pid \(grandchild))が生き残っている")
        _ = kill(grandchild, SIGKILL)  // 後始末(テストの失敗時に sleep を残さない)
    }

    /// **子が先に終わっても、孫がパイプを握っていれば EOF を待ち続けない**(timeout 無しの経路)。
    /// `(sleep 3) &` は sh の孫として stdout を継承する。sh 自身は即終了するので、出力の回収は
    /// 短い猶予(Shell.outputDrainGraceSeconds)で打ち切って返る
    func testExitedChildWithLingeringGrandchildDoesNotBlockUntilEOF() throws {
        let start = Date()
        let result = try Shell.run(["sh", "-c", "(sleep 3) & echo hi"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("hi"), result.output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5, "孫の EOF を 3 秒待ってしまった")
    }

    /// 64KB を超える出力でも詰まらない(パイプ飽和で子がブロックし waitpid が返らない形の回帰)
    func testLargeOutputDoesNotDeadlock() throws {
        let result = try Shell.run(["sh", "-c", "head -c 300000 /dev/zero | tr '\\0' x"], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 300000)
    }

    /// exit code とシグナル終了の写像(Foundation.Process と同じ: 通常終了は exit code・
    /// シグナルで死んだらそのシグナル番号)
    func testStatusMappingMatchesProcess() throws {
        XCTAssertEqual(try Shell.run(["sh", "-c", "exit 3"]).status, 3)
        XCTAssertEqual(try Shell.run(["sh", "-c", "kill -TERM $$"]).status, Int32(SIGTERM))
    }

    /// cwd と stderr の扱い(runData は stdout だけ)
    func testCwdAndStderrHandling() throws {
        let tmp = FileManager.default.temporaryDirectory
        let pwd = try Shell.run(["pwd"], cwd: tmp).output.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: pwd).standardizedFileURL.resolvingSymlinksInPath().path,
                       tmp.standardizedFileURL.resolvingSymlinksInPath().path)
        let merged = try Shell.run(["sh", "-c", "echo out; echo err 1>&2"]).output
        XCTAssertTrue(merged.contains("out") && merged.contains("err"))
        let stdoutOnly = try Shell.runData(["sh", "-c", "echo out; echo err 1>&2"])
        XCTAssertEqual(String(data: stdoutOnly.data, encoding: .utf8), "out\n")
    }

    /// timeout=nil(既存経路)は従来どおり動作する。
    func testNoTimeoutPathUnchanged() throws {
        let result = try Shell.run(["echo", "no-timeout"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "no-timeout")
    }
}
