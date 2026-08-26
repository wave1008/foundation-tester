// 「縁の帯に潜った対象を、撃つ前に1回だけ送って外す」判定の固定。
// 外せない形(暗幕・全画面モーダル・横の重なり)で送ると、画面を動かした挙句に
// 同じ物に当たる = 副作用だけ増えるので、その3形は nil でなければならない。
import XCTest
@testable import FTCore

final class UncoverScrollJumpTests: XCTestCase {

    private let container = FTRect(x: 0, y: 100, width: 375, height: 500)

    private func element(_ type: String, _ rect: FTRect, ref: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: nil, value: nil,
                    placeholder: nil, enabled: true, frame: rect, depth: 2)
    }

    /// 下部タブバーに潜ったボタン(受け手の 4.7 インチ実機で7本が落ちた形)
    func testBottomBandLiftsTheTargetUp() {
        let target = element("button", FTRect(x: 16, y: 560, width: 340, height: 48))
        let tabBar = element("tab", FTRect(x: 0, y: 552, width: 375, height: 50))
        guard let jump = TapTargetGeometry.uncoverScrollJump(
            target: target, coveredBy: tabBar, container: container) else {
            return XCTFail("下の帯は送って外せる形なのに nil")
        }
        XCTAssertGreaterThan(jump, 0, "対象を上へ動かす向き(指を上へ)でなければならない")
    }

    /// 上部のバーに潜った対象は逆向き
    func testTopBandPushesTheTargetDown() {
        let target = element("button", FTRect(x: 16, y: 110, width: 340, height: 48))
        let navBar = element("button", FTRect(x: 0, y: 96, width: 375, height: 44))
        let jump = TapTargetGeometry.uncoverScrollJump(
            target: target, coveredBy: navBar, container: container)
        XCTAssertNotNil(jump)
        XCTAssertLessThan(jump ?? 0, 0)
    }

    /// **帯の下端が容器の下端と揃っていなくても外せる**(タブバーはセーフエリアぶん内側)。
    /// E2E-iOS の witness の実測値(帯 778..840 / 容器 200..873 / 対象 788..850)
    func testTabBarNotFlushWithTheContainerEdge() {
        let container = FTRect(x: 0, y: 200, width: 402, height: 673)
        let target = element("button", FTRect(x: 16, y: 788, width: 370, height: 62))
        let tabBar = element("button", FTRect(x: 134, y: 778, width: 134, height: 62))
        let jump = TapTargetGeometry.uncoverScrollJump(
            target: target, coveredBy: tabBar, container: container)
        XCTAssertNotNil(jump, "セーフエリアぶん内側の帯でも外せなければ実機の形を救えない")
        XCTAssertGreaterThan(jump ?? 0, 0)
    }

    /// dragGesture は 50pt 未満のドラッグを捨てるので、必要量が小さくても切り上げる
    func testSmallOverlapStillProducesAUsableDrag() {
        let target = element("button", FTRect(x: 16, y: 545, width: 340, height: 20))
        let tabBar = element("tab", FTRect(x: 0, y: 558, width: 375, height: 42))
        let jump = TapTargetGeometry.uncoverScrollJump(
            target: target, coveredBy: tabBar, container: container)
        XCTAssertGreaterThanOrEqual(jump ?? 0, 60)
    }

    /// 暗幕・装飾は送っても外れない(操作可能でない覆いは対象外)
    func testNonOperableOverlayIsNotWorthScrolling() {
        let target = element("button", FTRect(x: 16, y: 560, width: 340, height: 48))
        let scrim = element("other", FTRect(x: 0, y: 550, width: 375, height: 50))
        XCTAssertNil(TapTargetGeometry.uncoverScrollJump(
            target: target, coveredBy: scrim, container: container))
    }

    /// 全画面のモーダルは送っても外に出ない
    func testFullScreenOverlayIsNotWorthScrolling() {
        let target = element("button", FTRect(x: 16, y: 300, width: 340, height: 48))
        let modal = element("button", FTRect(x: 0, y: 100, width: 375, height: 500))
        XCTAssertNil(TapTargetGeometry.uncoverScrollJump(
            target: target, coveredBy: modal, container: container))
    }

    /// 容器の中心線を跨ぐ覆い(中央のダイアログ等)はどちらへ送っても外れない
    func testFloatingOverlayIsNotWorthScrolling() {
        let target = element("button", FTRect(x: 16, y: 330, width: 340, height: 48))
        let over = element("button", FTRect(x: 16, y: 320, width: 200, height: 80))
        XCTAssertNil(TapTargetGeometry.uncoverScrollJump(
            target: target, coveredBy: over, container: container))
    }
}
