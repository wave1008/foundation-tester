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
}
