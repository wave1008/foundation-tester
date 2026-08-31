// RotationSettle.framesFitScreen の純ロジックを検証する。デバイスに触れない。

import XCTest
@testable import FTCore

final class RotationSettleTests: XCTestCase {
    private func element(x: Double, y: Double, width: Double, height: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: nil, label: nil, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: x, y: y, width: width, height: height), depth: 0)
    }

    private func snapshot(screen: FTRect, elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }

    /// 実機 iPhone 13 の witness(2026-08-31): 回転直後の1枚目。screen は新しい向き(390x844)
    /// なのに `#screen_wishlist` は旧向きのレイアウトのまま(17,35 519x537) — 右端 536 が
    /// 幅 390 を大きく超えている。中心 x=276.5 は幅の内側に収まるので、中心判定なら見逃す
    func testWitnessLandscapeSizedFrameOnPortraitScreenDoesNotFit() {
        let screen = FTRect(x: 0, y: 0, width: 390, height: 844)
        let wishlist = element(x: 17, y: 35, width: 519, height: 537)
        let tab = element(x: 17, y: 572, width: 97, height: 80)
        XCTAssertFalse(RotationSettle.framesFitScreen(snapshot(screen: screen,
                                                                elements: [wishlist, tab])))
    }

    /// 収まっている portrait の木は fit と判定する
    func testConsistentPortraitTreeFits() {
        let screen = FTRect(x: 0, y: 0, width: 390, height: 844)
        let card = element(x: 17, y: 35, width: 356, height: 200)
        let tab = element(x: 17, y: 780, width: 356, height: 44)
        XCTAssertTrue(RotationSettle.framesFitScreen(snapshot(screen: screen,
                                                               elements: [card, tab])))
    }

    /// 収まっている landscape の木も同じ規則で fit と判定する(向き自体は問わない)
    func testConsistentLandscapeTreeFits() {
        let screen = FTRect(x: 0, y: 0, width: 844, height: 390)
        let card = element(x: 35, y: 17, width: 500, height: 300)
        let tab = element(x: 700, y: 17, width: 97, height: 80)
        XCTAssertTrue(RotationSettle.framesFitScreen(snapshot(screen: screen,
                                                               elements: [card, tab])))
    }

    /// 1pt の丸め誤差は許容する(縁がちょうど許容量ぶんだけはみ出す)
    func testRoundingWithinToleranceStillFits() {
        let screen = FTRect(x: 0, y: 0, width: 390, height: 844)
        let almost = element(x: 0, y: 0, width: 391, height: 844)
        XCTAssertTrue(RotationSettle.framesFitScreen(snapshot(screen: screen, elements: [almost])))
    }
}
