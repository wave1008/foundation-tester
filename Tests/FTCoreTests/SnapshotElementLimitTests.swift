// `?max=` の解釈(BridgeAPI.resolvedSnapshotElementLimit)。**ホストと3ブリッジで同じ規則**
// でなければならず、Java 側(SnapshotBuilder.resolveElementLimit)はここを写したもの。
// 規則が割れると「上げたのに上がらない」「上げすぎて応答が壊れる」が OS ごとに起きる。

import XCTest
@testable import FTCore

final class SnapshotElementLimitTests: XCTestCase {

    func testOmittedOrNonPositiveFallsBackToTheDefault() {
        XCTAssertEqual(BridgeAPI.resolvedSnapshotElementLimit(nil), BridgeAPI.maxSnapshotElements)
        XCTAssertEqual(BridgeAPI.resolvedSnapshotElementLimit(0), BridgeAPI.maxSnapshotElements)
        XCTAssertEqual(BridgeAPI.resolvedSnapshotElementLimit(-5), BridgeAPI.maxSnapshotElements)
    }

    /// **既定より小さい値も通す**: 読み手が意図的に絞ることはあり得るので勝手に押し上げない
    func testAValueBelowTheDefaultIsHonoured() {
        XCTAssertEqual(BridgeAPI.resolvedSnapshotElementLimit(30), 30)
    }

    func testValuesAreClampedToTheCeiling() {
        XCTAssertEqual(BridgeAPI.resolvedSnapshotElementLimit(200), 200)
        XCTAssertEqual(BridgeAPI.resolvedSnapshotElementLimit(10_000),
                       BridgeAPI.maxSnapshotElementsCeiling)
    }

    /// 天井は既定より大きくなければ引き上げ自体が成立しない(定数を取り違えたら落ちる)
    func testCeilingIsAboveTheDefault() {
        XCTAssertGreaterThan(BridgeAPI.maxSnapshotElementsCeiling, BridgeAPI.maxSnapshotElements)
    }

    /// **Java 側の写しと規則が一致していること**をソース走査で確かめる(片方だけ直す事故を防ぐ。
    /// 値そのものを Java から実行できないので、定数の一致だけを機械で見る)
    func testJavaMirrorDeclaresTheSameConstants() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let java = try String(contentsOf: root.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java"), encoding: .utf8)
        XCTAssertTrue(java.contains("MAX_ELEMENTS = \(BridgeAPI.maxSnapshotElements)"),
                      "Java の MAX_ELEMENTS が BridgeAPI.maxSnapshotElements と違う")
        XCTAssertTrue(java.contains("MAX_ELEMENTS_CEILING = \(BridgeAPI.maxSnapshotElementsCeiling)"),
                      "Java の MAX_ELEMENTS_CEILING が BridgeAPI.maxSnapshotElementsCeiling と違う")
    }

    /// 間引きは指定された上限で効くこと(**上限を渡しても既定で切っていたら意味がない**)
    func testThinningHonoursTheRequestedLimit() {
        let candidates = (1...300).map { ref in
            BridgeSnapshotThinning.Candidate(info: ElementInfo(
                ref: ref, type: "staticText", identifier: nil, label: "row \(ref)",
                value: nil, placeholder: nil, enabled: true,
                frame: FTRect(x: 0, y: Double(ref), width: 100, height: 10), depth: 1))
        }
        XCTAssertEqual(BridgeSnapshotThinning.indicesToKeep(candidates, max: 120).count, 120)
        XCTAssertEqual(BridgeSnapshotThinning.indicesToKeep(candidates, max: 250).count, 250)
    }
}
