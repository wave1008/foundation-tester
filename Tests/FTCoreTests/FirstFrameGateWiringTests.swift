// launch 直後の launch storyboard(一様色)を occlusion-guard の誤った赤にしない一度きりの門
// (StepExecutor.firstFrameGatePending)の配線ゲート。判定そのものは
// StepExecutorTests の testFirstFrameGate* が見るが、「arm する呼び出しが launch 系サイトから
// 消えている」変異はコンパイラでは止まらないので、ソースを読んで固定する
// (OverlayWindowOcclusionWiringTests と同型)。

import XCTest

final class FirstFrameGateWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/FTCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // リポジトリ直下

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/" + relativePath),
                    encoding: .utf8)
    }

    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// noteAppLaunched() 自身が門を arm すること。**armUnregisteredSystemAlertProbe() 単体では
    /// arm しない**(CAE の各フェーズ先頭で毎回呼ばれるので、そちらに乗せると launch 系以外の
    /// フェーズ境界でも猶予が発生してしまう)
    func testNoteAppLaunchedArmsTheGate() throws {
        let text = compact(try source("FTCore/StepExecutor.swift"))
        XCTAssertTrue(text.contains(compact("""
            funcnoteAppLaunched(){armUnregisteredSystemAlertProbe()firstFrameGatePending=true}
            """)),
            "noteAppLaunched() が firstFrameGatePending を arm していない")
        XCTAssertFalse(text.contains(compact("""
            funcarmUnregisteredSystemAlertProbe(){systemAlertProbePending=true;firstFrameGatePending=true}
            """)),
            "armUnregisteredSystemAlertProbe() 単体で arm すると、CAE の毎フェーズで門が開いてしまう")
    }

    /// launch 系コマンド("launchApp"/"restartApp"/"clearAppData"/"installApp")の直後で
    /// noteAppLaunched() を呼ぶ箇所が FTRuntime に実在すること(systemAlertProbePending と
    /// 同じ launch サイト。片方だけ変えると門が二度と開かなくなる)
    func testFTRuntimeCallsNoteAppLaunchedAtLaunchSites() throws {
        let text = compact(try source("FTDSL/FTRuntime.swift"))
        XCTAssertTrue(text.contains(compact(
            "[\"launchApp\", \"restartApp\", \"clearAppData\", \"installApp\"].contains(command)")),
            "launch 系コマンドの一覧が変わっている(systemAlertProbePending と同じ一覧のはず)")
        XCTAssertTrue(text.contains(compact("""
            if let command, ["launchApp", "restartApp", "clearAppData", "installApp"].contains(command) {
                executor.noteAppLaunched()
            }
            """)),
            "launch 系コマンドの直後で executor.noteAppLaunched() を呼んでいない")
    }
}
