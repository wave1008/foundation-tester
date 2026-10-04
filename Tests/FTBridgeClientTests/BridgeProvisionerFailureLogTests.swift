// 供給が**全滅した回でも、1台ずつ理由が残る**ことの回帰。
//
// なぜ要るか(2026-09-04 の実機調査): `FleetOutcome.resolve` は全滅のとき**最初の1件だけ**を
// throw する規約で、`BridgeProvisioner` の per-device ログはその後ろに置かれていた。
// そのため8台が同時に落ちた回の記録が1ポートぶんしか残らず、「全機が同じ理由で死んだのか、
// 別々の理由なのか」を後から言えなかった —— 原因の切り分けが1回ぶん丸ごと潰れる。
//
// 配線はソース走査で固定する(供給そのものは実デバイスを要求するのでテストから通せない)。

import XCTest

final class BridgeProvisionerFailureLogTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリ直下
            .appendingPathComponent("Sources/FTBridgeClient/BridgeProvisioner.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// **理由の出力が resolve より前にあること**。順序が入れ替わると、全滅の回だけ静かになる
    func testEveryFailureIsLoggedBeforeTheThrowingResolve() throws {
        let text = try source()
        let logIndex = try XCTUnwrap(compact(text).range(of: compact(
            "if case .failure(let error) = outcome.result {safeLog(")))
        let resolveIndex = try XCTUnwrap(compact(text).range(of: compact(
            "let resolved = try Self.resolveOutcomes(collected)")))
        XCTAssertTrue(logIndex.upperBound <= resolveIndex.lowerBound,
                      "1台ずつの理由が resolveOutcomes より後に出ている ——"
                      + " 全滅の回は throw が先に走るので、その記録が丸ごと消える")
    }

    /// 集めた結果を**そのまま** resolve へ渡していること(ログ用に別の配列を作って
    /// 片方だけ絞ると、出力と判定が食い違う)
    func testTheSameCollectionFeedsBothTheLogAndTheResolve() throws {
        let text = compact(try source())
        XCTAssertTrue(text.contains(compact("for outcome in collected {")))
        XCTAssertTrue(text.contains(compact("try Self.resolveOutcomes(collected)")))
    }

    /// **起動より前の段(UDID の解決・採番)で落ちた機も、その機だけの失敗として集約へ合流すること**。
    /// 手順1/4 で throw すると、Simulator が1台消えた(作り直された)・実機が1台外れただけで
    /// 健全な残り全台の iOS レーンが空になる
    func testResolveAndPlanningFailuresStayPerDevice() throws {
        let text = compact(try source())
        XCTAssertTrue(text.contains(compact(
            "do { let sim = try SimulatorCatalog.resolve(spec: device.spec, in: catalog)")),
            "UDID の解決が do/catch の外にある —— 1台の解決失敗が provision 全体の throw になる")
        let planning = try XCTUnwrap(text.range(of: compact("do { if engine == \"hybrid\" {")),
                                     "採番の do ブロックが見つからない")
        let planningCatch = try XCTUnwrap(text.range(
            of: compact("} catch { earlyFailures[index] = error continue }"),
            range: planning.upperBound..<text.endIndex))
        let planningBody = text[planning.lowerBound..<planningCatch.lowerBound]
        XCTAssertEqual(planningBody.components(separatedBy: "tryplanBridge(").count - 1, 3,
                       "planBridge の3呼び出しのどれかが採番の do/catch の外にある")
        XCTAssertEqual(text.components(separatedBy: "tryplanBridge(").count - 1, 3)
        XCTAssertEqual(text.components(separatedBy: "trySimulatorCatalog.resolve(").count - 1, 1)
        XCTAssertTrue(text.contains(compact(
            "if let error = earlyFailures[index] { return (name: devices[index].name, result: .failure(error)) }")),
            "早い段の失敗が集約(collected)へ合流していない —— 理由のログも全滅の throw も欠ける")
    }
}
