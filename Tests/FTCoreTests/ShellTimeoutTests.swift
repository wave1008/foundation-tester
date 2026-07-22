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
        let result = try Shell.run(["echo", "hello-ftester"], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello-ftester")
    }

    /// 非ゼロ exit code も timeout 経路で正しく伝播する(タイムアウトと誤検出しない)。
    func testNonZeroExitPropagatesWithoutTimeout() throws {
        let result = try Shell.run(["false"], timeout: 10)
        XCTAssertNotEqual(result.status, 0)
    }

    /// timeout=nil(既存経路)は従来どおり動作する。
    func testNoTimeoutPathUnchanged() throws {
        let result = try Shell.run(["echo", "no-timeout"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "no-timeout")
    }
}
