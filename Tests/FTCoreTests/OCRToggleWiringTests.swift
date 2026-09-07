// `ocr`(occlusion guard 前段の Vision OCR 事前判定)は
// プロファイル → RunOrchestrator/ScenarioRunner → 子プロセス CLI フラグ → 実行時の
// occlusionOCRMode という何段もの境界を越える。単体テストはデバイスを起こさずには
// 実行時の挙動を観測できないので、各段のソースに配線が残っているかを走査で固定する。
// **どこか1段が欠けると、プロファイルで `ocr: false` にしても黙って無視される**。

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

    func testScenarioHostForwardsOcrToTheChildRunner() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertTrue(host.contains("if !ocr { args.append(\"--no-ocr\") }"),
                      "ocr が子ランナーへ伝わっていない(切っても子は知らないまま走る)")
    }

    func testScenarioRunnerMainWiresTheFlagIntoTheRuntime() throws {
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains("customLong(\"no-ocr\")"), "--no-ocr を受け取れない")
        XCTAssertTrue(runner.contains("ocrEnabled: !noOcr"),
                      "--no-ocr を実行時へ渡していない(受け取っても捨てている)")
    }

    /// 折り返しで落ちないよう空白を畳んでから見る(整形で配線の検査が消えるのを防ぐ)
    func testFTRuntimeGatesTheEnvVarWithTheProfileToggle() throws {
        let runtime = try source("Sources/FTDSL/FTRuntime.swift")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(
            runtime.contains(
                "ocrEnabled ? RegionText.mode(environment: ProcessInfo.processInfo.environment) : .off"),
            "ocrEnabled=false のとき FT_OCCLUSION_OCR を読んでしまう(プロファイルが環境変数に負ける)")
    }

    /// `ScenarioRunner.runOne` → `ScenarioHost.run` と `RunOrchestrator` → `ScenarioRunner.runOne` の
    /// 2つの呼び出しどちらでも渡していること。名前だけでは呼び出し元を区別できないので出現数で見る
    func testRunOrchestratorThreadsOcrAtBothCallSites() throws {
        let orchestrator = try source("Sources/FTCore/RunOrchestrator.swift")
        let occurrences = orchestrator.components(separatedBy: "ocr: ocr").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 2,
                                    "ocr: ocr が2箇所未満(runOne→ScenarioHost.run か "
                                    + "RunOrchestrator→runOne のどちらかで配線が落ちている)")
    }

    func testProfileRunnerPassesResolvedOcrToTheOrchestrator() throws {
        let profileRunner = try source("Sources/fleetest/ProfileRunner.swift")
        XCTAssertTrue(profileRunner.contains("ocr: resolved.ocrFalsePositiveCheck"),
                      "実効値(親 ocr を掛けた後)が RunOrchestrator へ渡っていない")
    }

    /// `--dry-run`/`--debug` の resolved-profile 経路と `--profile` 並列ワーカー経路の両方
    func testApiRunCommandPassesResolvedOcrAtBothCallSites() throws {
        let apiRun = try source("Sources/fleetest/ApiRunCommand.swift")
        let occurrences = apiRun.components(separatedBy: "ocr: resolved.ocrFalsePositiveCheck").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 2,
                                    "ocr: resolved.ocr が2箇所未満(dry-run 経路か --profile 経路の "
                                    + "どちらかで配線が落ちている)")
    }
}
