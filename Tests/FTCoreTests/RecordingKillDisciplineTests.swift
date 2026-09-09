// 録画(simctl io recordVideo)の停止規律のソース走査。
//
// **実測 2026-09-09**: SIGINT 以外で recordVideo の client を殺すと、**端末側のセッションが
// 握られたまま残る**(実験: 該当台は "Host recording is already in progress" を返し続け、
// シャットダウンで初めて解けた)。ツールは猶予切れで SIGKILL していたため、**自分で作った
// セッションを自分で「残っている」と警告する**形になっていた。
//
// 停止は SIGINT だけ。止まらない個体は放置する(次の run の smokeCheck が busy として報告する)。
// 型では守れない規律なのでソースで見る(ShellSourceScanTests / ProcessLivenessSourceScanTests と同型)。

import XCTest

final class RecordingKillDisciplineTests: XCTestCase {

    private func recorderSource(file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // FTCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
        let path = root.appendingPathComponent("Sources/FTCore/IOSSimulatorVideoRecorder.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// コメントは対象外(規律の理由を書いてあるため)。**コードの行だけ**を見る。
    private func codeLines(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testRecorderNeverSendsSIGKILL() throws {
        let source = codeLines(try recorderSource())
        XCTAssertFalse(source.contains("SIGKILL"),
                       "recordVideo の client を SIGKILL すると端末側の録画セッションが残り、"
                       + "その台は再起動まで録画できなくなる(停止は SIGINT だけ)")
    }

    /// stale な client の掃除も SIGINT(pkill の既定は SIGTERM で、同じ穴に落ちる)
    func testStaleRecorderCleanupUsesSIGINT() throws {
        let source = codeLines(try recorderSource())
        XCTAssertTrue(source.contains("\"pkill\", \"-INT\""),
                      "killStaleRecording は pkill -INT で止めること(既定の SIGTERM は不可)")
    }

    /// 走査が本物のソースに当たっていることの確認(パスを間違えたまま緑になる型を塞ぐ)
    func testScanReachesTheRealSource() throws {
        let source = codeLines(try recorderSource())
        XCTAssertTrue(source.contains("recordVideo"), "走査対象のソースを読めていない")
        XCTAssertTrue(source.contains("process.interrupt()"), "SIGINT で止める実装が見当たらない")
    }
}
