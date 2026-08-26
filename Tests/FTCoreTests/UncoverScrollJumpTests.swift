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

/// **送るときに指を当てる領域**(覆いを避けた容器の残り)の固定。
/// 容器をそのまま渡すと覆いの上をなぞることになり、何も動かない。
final class UncoverDragAreaTests: XCTestCase {

    private let container = FTRect(x: 0, y: 140, width: 402, height: 700)

    func testBottomCoverLeavesTheAreaAboveIt() {
        let keyboard = FTRect(x: 0, y: 573, width: 402, height: 301)
        guard let area = TapTargetGeometry.uncoverDragArea(container: container, cover: keyboard) else {
            return XCTFail("覆いの上に 433pt 残っているのに nil")
        }
        XCTAssertEqual(area.y, 140)
        XCTAssertEqual(area.y + area.height, 573, "指がキーボードの上に乗ってはいけない")
    }

    func testTopCoverLeavesTheAreaBelowIt() {
        let navBar = FTRect(x: 0, y: 140, width: 402, height: 88)
        let area = TapTargetGeometry.uncoverDragArea(container: container, cover: navBar)
        XCTAssertEqual(area?.y, 228)
    }

    /// 残りが狭すぎるとドラッグが成立しない(dragGesture が捨てる)ので送らない
    func testTooLittleRoomIsRefused() {
        let keyboard = FTRect(x: 0, y: 200, width: 402, height: 674)
        XCTAssertNil(TapTargetGeometry.uncoverDragArea(container: container, cover: keyboard))
    }
}

/// 申告が無い木でのキーボード帯の推定(送る判断専用)。
/// **警告の意味は変えない** —— `KeyboardOcclusion` は申告が無ければ「キーボード無し」のまま。
final class KeyboardBandFromChromeTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ id: String?, _ rect: FTRect, ref: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true, frame: rect, depth: 2)
    }

    /// 実測の形(E2E-iOS の UIKit 入力): キーボードが `other id=inputView` として出る
    func testChromeAtTheBottomEdgeIsTakenAsTheKeyboard() {
        let elements = [element("inputView", FTRect(x: 0, y: 573, width: 402, height: 301))]
        let band = TapTargetGeometry.keyboardBandFromChrome(in: elements, screen: screen)
        XCTAssertEqual(band?.y, 573)
        XCTAssertEqual(band.map { $0.y + $0.height }, 874)
    }

    /// 画面の下端に接していない同名要素は採らない(矩形の暴発を防ぐ)
    func testChromeAwayFromTheBottomEdgeIsIgnored() {
        let elements = [element("inputView", FTRect(x: 0, y: 0, width: 402, height: 50))]
        XCTAssertNil(TapTargetGeometry.keyboardBandFromChrome(in: elements, screen: screen))
    }

    func testNoChromeMeansNoBand() {
        let elements = [element("some_row", FTRect(x: 0, y: 800, width: 402, height: 74))]
        XCTAssertNil(TapTargetGeometry.keyboardBandFromChrome(in: elements, screen: screen))
    }
}
