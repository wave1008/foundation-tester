// 「起動中のブリッジを待つ」経路が、**既に終わったテストセッションを待ち続けない**ことを守る。
//
// ランナーが落ちても xcodebuild は後始末の間だけ生きて `ps` に残るので、**pid の生死では
// 判定できない**(最初にそれを実装して、発火し得ないことに気付いた)。判定材料はログの
// 終端マーカーだけ。見落とすと `waitUntilReady` の既定 180 秒を丸ごと捨ててから作り直す
// ことになり、次の provision が 3 分級になる(2026-08-05 に実機で踏んだ)。
//
// ログは起動のたびに空で作り直される(startDetached の createFile)ので、
// **見つかったマーカーは必ず今回のもの** —— 前回の残骸で誤爆する心配はしなくてよい。

import XCTest
@testable import FTBridgeClient

final class RunnerSessionEndedTests: XCTestCase {

    func testDetectsTheMarkersXcodebuildPrintsWhenTheSessionIsOver() {
        XCTAssertEqual(
            BridgeLauncher.runnerSessionEnded(inLog: "…\n** TEST EXECUTE FAILED **\n"),
            "** TEST EXECUTE FAILED **")
        XCTAssertEqual(
            BridgeLauncher.runnerSessionEnded(inLog: "…\n** BUILD INTERRUPTED **\n"),
            "** BUILD INTERRUPTED **")
        XCTAssertEqual(
            BridgeLauncher.runnerSessionEnded(inLog: "Testing failed:\n\tFTesterBridgeTests…"),
            "Testing failed:")
    }

    /// **待ちのループが実際に即座に降りる**こと(判定関数が正しくても、ループが見ていなければ
    /// 180 秒待つ)。応答しないポート + 終端マーカー入りのログで、1 秒以内に throw すること
    func testWaitUntilReadyGivesUpImmediatelyOnAnEndedSession() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-ended-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".ftester"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 誰も listen していないポート(接続拒否ですぐ返る)
        let launcher = BridgeLauncher(repoRoot: root, device: "UDID-1", port: 8199)
        try "…\n** TEST EXECUTE FAILED **\n".write(to: launcher.logPath, atomically: true,
                                                   encoding: .utf8)

        let started = Date()
        do {
            try await launcher.waitUntilReady(timeout: 180)
            XCTFail("終わったセッションを ready と見なしてはいけない")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                              "既定の 180 秒を待ってしまっている: \(error)")
        }
    }

    /// **起動中のログでは止めない**(ビルド〜起動の途中経過は正常。ここで誤検知すると
    /// 立ち上がる寸前のランナーを毎回殺して作り直すことになる)
    func testStartingLogIsNotMistakenForAnEndedSession() {
        let starting = """
            Testing started
            2026-08-05 03:00:00.000 xcodebuild[1:1] [MT] IDETestOperationsObserverDebug: …
            Test session results, code coverage, and logs:
            """
        XCTAssertNil(BridgeLauncher.runnerSessionEnded(inLog: starting))
        XCTAssertNil(BridgeLauncher.runnerSessionEnded(inLog: ""))
    }
}
