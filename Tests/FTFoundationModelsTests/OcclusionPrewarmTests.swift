// occlusion の暖機(prewarm)の契約。**FM を実際に暖める部分は単体テストで踏まない**
// (ホスト共有資源。効果と害は実 run の A/B で見る。docs/performance-tuning.md §3.5.1)。
// ここで固定するのは殺しスイッチ・スロットの受け渡し規則・1段目がスロットを使うこと。

import XCTest
@testable import FTFoundationModels

final class OcclusionPrewarmTests: XCTestCase {

    override func tearDown() {
        OcclusionPrewarm.resetForTesting()
        super.tearDown()
    }

    func testPrewarmIsOnByDefault() {
        XCTAssertTrue(OcclusionVerifier.prewarmEnabled(environment: [:]))
        XCTAssertTrue(OcclusionVerifier.prewarmEnabled(environment: ["FT_FM_OCCLUSION_PREWARM": "1"]))
        // 切るのは明示の "0" だけ(想定外の値は切らない側に倒す)
        XCTAssertTrue(OcclusionVerifier.prewarmEnabled(environment: ["FT_FM_OCCLUSION_PREWARM": "off"]))
    }

    func testKillSwitchTurnsItOff() {
        XCTAssertFalse(OcclusionVerifier.prewarmEnabled(environment: ["FT_FM_OCCLUSION_PREWARM": "0"]))
    }

    /// 空のスロットからは取れない(= その場でセッションを作る従来の経路へ落ちる)
    func testTakeOnEmptySlotReturnsNil() {
        OcclusionPrewarm.resetForTesting()
        XCTAssertNil(OcclusionPrewarm.take(matching: OcclusionVerifier.instructions))
        XCTAssertFalse(OcclusionPrewarm.isHoldingForTesting)
    }

    /// **instructions は暖機と本番で同一**でなければ意味が無い(prefill は instructions ごと)。
    /// 1段目がスロットを引く鍵と、暖機が置く鍵が同じ定数であることをソースで固定する
    func testPrewarmAndCallUseTheSameInstructions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let verifier = try String(
            contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/OcclusionVerifier.swift"),
            encoding: .utf8)
        let delegate = try String(
            contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/ReplayAssist.swift"),
            encoding: .utf8)
        XCTAssertTrue(verifier.contains("respond(instructions: Self.instructions"),
                      "本番の呼び出しが共有の instructions 定数を使っていない")
        XCTAssertTrue(verifier.contains("OcclusionPrewarm.take(matching: instructions)"),
                      "1段目が暖機済みセッションを引いていない(暖機が無駄になる)")
        XCTAssertTrue(delegate.contains("OcclusionPrewarm.prewarm(instructions: OcclusionVerifier.instructions)"),
                      "暖機が共有の instructions 定数で撃たれていない")
    }

    /// 死んでいる FM を暖め続けない(門は通らないので、ブレーカだけが歯止め)
    func testPrewarmChecksTheBreaker() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let delegate = try String(
            contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/ReplayAssist.swift"),
            encoding: .utf8)
        let body = try XCTUnwrap(Self.functionBody(named: "prewarmVisibilityCheck", in: delegate))
        XCTAssertTrue(body.contains("FMBreaker.isOpen"),
                      "暖機がブレーカを見ていない(FM が死んだホストで暖機だけ回り続ける)")
        XCTAssertFalse(body.contains("FMHealth.record"),
                       "暖機を FMHealth へ記録している(呼び出し回数とレートが実態より多く見える)")
    }

    static func functionBody(named name: String, in source: String) -> String? {
        guard let found = source.range(of: "func \(name)("),
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
