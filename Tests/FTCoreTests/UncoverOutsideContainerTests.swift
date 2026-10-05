// 容器の外のバー(スクロールで隠れる上部バー)が容器の縁に接する名前つきの物に覆われたとき、
// 主たる縦の容器を戻して外す判定の固定。形は E2EY-Flutter「スクロールで隠れるバー」の木。
import XCTest
@testable import FTCore

final class UncoverOutsideContainerTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    private let list = FTRect(x: 0, y: 174, width: 402, height: 700)

    private func el(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil,
                    _ r: FTRect, scrollable: Bool? = nil) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                            placeholder: nil, enabled: true, frame: r, depth: 2)
        e.scrollable = scrollable
        return e
    }

    func testPrimaryContainerPicksTheBigVerticalScroller() {
        let lane = el(2, "other", FTRect(x: 0, y: 400, width: 402, height: 48), scrollable: true)
        let big = el(3, "other", FTRect(x: 0, y: 174, width: 402, height: 700), scrollable: true)
        XCTAssertEqual(TapTargetGeometry.primaryScrollContainer(in: [lane, big], screen: screen)?.ref, 3)
        XCTAssertNil(TapTargetGeometry.primaryScrollContainer(in: [lane], screen: screen))
    }

    func testNamedCoverAboveContainerPullsContentDown() {
        let target = el(1, "button", id: "btn_top_action", label: "並べ替え",
                        FTRect(x: 333, y: 100, width: 56, height: 20))
        let cover = el(2, "staticText", label: "受信トレイ", FTRect(x: 16, y: 148, width: 305, height: 26))
        let jump = TapTargetGeometry.uncoverOutsideScrollJump(target: target, coveredBy: cover, container: list)
        XCTAssertLessThan(jump ?? 0, 0, "上の覆いは内容を下へ戻す向き(負)")
    }

    func testCoverNotTouchingTheContainerEdgeIsNil() {
        let target = el(1, "button", label: "x", FTRect(x: 333, y: 100, width: 56, height: 20))
        let cover = el(2, "staticText", label: "受信トレイ", FTRect(x: 16, y: 90, width: 305, height: 26))
        XCTAssertNil(TapTargetGeometry.uncoverOutsideScrollJump(target: target, coveredBy: cover, container: list))
    }

    func testTargetInsideContainerIsLeftToTheOrdinaryLift() {
        let target = el(1, "button", label: "x", FTRect(x: 16, y: 200, width: 340, height: 48))
        let cover = el(2, "staticText", label: "見出し", FTRect(x: 0, y: 148, width: 402, height: 26))
        XCTAssertNil(TapTargetGeometry.uncoverOutsideScrollJump(target: target, coveredBy: cover, container: list))
    }

    func testUnnamedCoverIsNil() {
        let target = el(1, "button", label: "x", FTRect(x: 333, y: 100, width: 56, height: 20))
        let cover = el(2, "other", FTRect(x: 0, y: 148, width: 402, height: 26))
        XCTAssertNil(TapTargetGeometry.uncoverOutsideScrollJump(target: target, coveredBy: cover, container: list))
    }

    /// 形3: 一覧の上に浮いた FAB は、容器の外へはみ出た中身(ghost)ではない。仲間の居る行は ghost のまま
    func testFloatingFabIsNotAGhostButAScrolledOutRowIs() {
        var els: [ElementInfo] = []
        els.append(el(1, "other", FTRect(x: 0, y: 168, width: 402, height: 706), scrollable: true))
        els[0].depth = 1
        var rows: [ElementInfo] = [(2, 200.0), (3, 252.0), (4, -10.0)].map { ref, y in
            var r = el(Int(ref), "button", label: "行", FTRect(x: 8, y: y, width: 386, height: 48)); r.depth = 3; return r }
        // 行は容器(wrapper)の中に並び、FAB は同じ深さで後ろに続く = 木の上では wrapper の兄弟で枠の外
        var wrapper = el(10, "other", FTRect(x: 0, y: 168, width: 402, height: 300)); wrapper.depth = 2
        els.insert(wrapper, at: 1)
        els += rows
        var fab = el(9, "button", id: "fab_hiding", FTRect(x: 330, y: 700, width: 56, height: 56)); fab.depth = 3
        els.append(fab)
        XCTAssertFalse(ContainerGeometry.isOutsideContainer(fab, in: els, screen: screen), "浮いた FAB は送らず撃つ")
        rows = els.filter { $0.ref == 4 }
        XCTAssertTrue(ContainerGeometry.isOutsideContainer(rows[0], in: els, screen: screen), "押し出された行は ghost のまま")
    }
}
