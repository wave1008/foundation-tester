// `occlusionOCR`(occlusion guard 前段の Vision OCR 事前判定)は `ScenarioExecutionSettings` に
// 乗って型で守られる区間(RunOrchestrator/ScenarioRunner/ScenarioHost)を通るが、子プロセス境界
// (CLI フラグ ⇄ FTRuntime の occlusionOCRMode)だけは型検査が効かない継ぎ目なので、
// ここが欠けると `occlusionOCR: false` にしても黙って無視される。走査で固定する。

import XCTest
@testable import FTCore

final class OCRToggleWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testScenarioHostForwardsOcclusionOCRToTheChildRunner() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertTrue(host.contains("if !occlusionOCR { args.append(\"--no-occlusion-ocr\") }"),
                      "occlusionOCR が子ランナーへ伝わっていない(切っても子は知らないまま走る)")
    }

    func testScenarioRunnerMainWiresTheFlagIntoTheRuntime() throws {
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains("customLong(\"no-occlusion-ocr\")"), "--no-occlusion-ocr を受け取れない")
        XCTAssertTrue(runner.contains("occlusionOCREnabled: !noOcclusionOCR"),
                      "--no-occlusion-ocr を実行時へ渡していない(受け取っても捨てている)")
    }

    /// 折り返しで落ちないよう空白を畳んでから見る(整形で配線の検査が消えるのを防ぐ)
    func testFTRuntimeGatesTheEnvVarWithTheProfileToggle() throws {
        let runtime = try source("Sources/FTDSL/FTRuntime.swift")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(
            runtime.contains(
                "occlusionOCRMode: occlusionOCREnabled "
                + "? RegionText.mode(environment: ProcessInfo.processInfo.environment) : .off"),
            "occlusionOCREnabled=false のとき FT_OCCLUSION_OCR を読んでしまう(プロファイルが環境変数に負ける)")
    }
}
