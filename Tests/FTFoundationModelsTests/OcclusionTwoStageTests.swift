// occlusion の2段化(1段目=reason を作らせない選別 / 2段目=反転したときだけ従来と同じ呼び出し)の契約。
// FM そのものは単体テストで踏めないので、**ここで固定できるのは分岐の入口(殺しスイッチ)・
// 予算(トークン上限)・段の形(欄の集合と早期 return の向き)・両段の計上**の4つ。
// 判定が変わらないことは実データで確かめてある(反転済み crop 147 枚 + 陽性 62 枚で全一致。
// docs/performance-tuning.md §3.5.1)。**欄を増減したら必ずコーパスで測り直すこと** ——
// スキーマ本文はプロンプトに入るので、欄の集合は判定に効く。

import XCTest
@testable import FTFoundationModels

final class OcclusionTwoStageTests: XCTestCase {

    func testTwoStageIsOnByDefault() {
        XCTAssertTrue(OcclusionVerifier.twoStageEnabled(environment: [:]))
        XCTAssertTrue(OcclusionVerifier.twoStageEnabled(environment: ["FT_FM_OCCLUSION_TWO_STAGE": "1"]))
        // 空文字・想定外の値は「切っていない」側に倒す(切るのは明示の "0" だけ)
        XCTAssertTrue(OcclusionVerifier.twoStageEnabled(environment: ["FT_FM_OCCLUSION_TWO_STAGE": ""]))
        XCTAssertTrue(OcclusionVerifier.twoStageEnabled(environment: ["FT_FM_OCCLUSION_TWO_STAGE": "off"]))
    }

    func testKillSwitchTurnsItOff() {
        XCTAssertFalse(OcclusionVerifier.twoStageEnabled(environment: ["FT_FM_OCCLUSION_TWO_STAGE": "0"]))
    }

    /// **期待値はリテラルで書く**(production の定数を参照すると、値を変える変異が素通りする)
    func testResponseTokenBudgetsArePinned() {
        XCTAssertEqual(OcclusionVerifier.screeningResponseTokens, 80)
        XCTAssertEqual(OcclusionVerifier.detailResponseTokens, 200)
    }

    /// 1段目の欄は「4欄から reason だけを落とした3欄」。**observedText を落としてはいけない**
    /// —— 実データで反転を 106/147 取りこぼした版がそれ(モデルが文字を読まなくなる)
    func testScreeningKeepsObservedTextAndDropsOnlyReason() throws {
        let source = try Self.verifierSource()
        let screening = try XCTUnwrap(Self.declarationBody(of: "struct VisibilityScreening", in: source))
        XCTAssertTrue(screening.contains("var visible: Bool"), "1段目に visible が無い")
        XCTAssertTrue(screening.contains("var state: VisibilityState"), "1段目に state が無い")
        XCTAssertTrue(screening.contains("var observedText: String"),
                      "1段目から observedText を落とすと判定が壊れる(実測 106/147 取りこぼし)")
        XCTAssertFalse(screening.contains("var reason"), "1段目に reason が残っている(削るのがこの段の目的)")
    }

    /// 2段とも FMHealth へ計上されること(成功・失敗の4本)。**本数で固定する** ——
    /// 段を足したのに計上を忘れると、結果 JSON の fm.calls とブレーカが実態より少なく数える
    /// (FMAccountingAuditTests は「関数の中に1本でもあるか」しか見ない)
    func testBothStagesAreAccounted() throws {
        let body = try XCTUnwrap(Self.functionBody(named: "respond", in: Self.verifierSource()))
        XCTAssertEqual(body.components(separatedBy: "FMHealth.record(kind: \"occlusion\"").count - 1, 4,
                       "respond の FM 計上が4本(選別の成功/失敗・詳細の成功/失敗)ではない")
        XCTAssertTrue(body.contains("VisibilityScreening.self"), "1段目が選別型を使っていない")
        XCTAssertTrue(body.contains("VisibilityVerdict.self"), "2段目が従来の型を使っていない")
        // 門は1回だけ取る(2段で2回取ると、間に他ワーカーが割り込んで crop と判定がずれる)
        XCTAssertEqual(body.components(separatedBy: "FMGate.enter()").count - 1, 1,
                       "FMGate を2回取っている(2段は1回の取得の中で回す)")
        // **早期 return の向き**。反転すると、覆われている回を2段目に回さず reason と crop を失い、
        // 見えている回で無駄に2回呼ぶ。FM を踏めない以上、向きはソースで固定するしかない
        XCTAssertTrue(body.contains("if screening.visible {"),
                      "1段目の早期 return が `screening.visible` で分岐していない")
        XCTAssertTrue(body.contains("return Result(visible: true,"),
                      "1段目が返すのは visible: true の結果だけであるべき")
    }

    // MARK: - ソースの切り出し

    static func verifierSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTFoundationModels/OcclusionVerifier.swift"),
                   encoding: .utf8)
    }

    static func functionBody(named name: String, in source: String) -> String? {
        balancedBody(after: "func \(name)(", in: source)
    }

    static func declarationBody(of declaration: String, in source: String) -> String? {
        balancedBody(after: declaration, in: source)
    }

    /// needle の後ろの `{` から中括弧の対応で本文を切り出す
    private static func balancedBody(after needle: String, in source: String) -> String? {
        guard let found = source.range(of: needle),
              let open = source[found.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
