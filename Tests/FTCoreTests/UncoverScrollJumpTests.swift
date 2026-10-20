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

    /// 貼り付く見出し(操作不能だが名前つき・容器の上端に揃う)に潜った行は送って外す。
    /// 実測の形(RN・Android px): 容器 (42,403 996x1979)・見出し (42,403 996x96)・行 (84,403 912x67)
    func testPinnedSectionHeaderIsLifted() {
        let container = FTRect(x: 42, y: 403, width: 996, height: 1979)
        let row = element("button", FTRect(x: 84, y: 403, width: 912, height: 67))
        var header = element("staticText", FTRect(x: 42, y: 403, width: 996, height: 96), ref: 2)
        header.label = "セクション B"
        let jump = TapTargetGeometry.uncoverScrollJump(target: row, coveredBy: header, container: container)
        XCTAssertNotNil(jump, "貼り付く見出しに潜った行は送れば外れる")
        XCTAssertLessThan(jump ?? 0, 0, "上の帯なので対象を下へ逃がす向き")
    }

    /// 名前つきでも**縁から浮いた**ラベル・幅の狭いラベルは帯ではない
    func testNamedLabelAwayFromTheEdgeIsNotABand() {
        let target = element("button", FTRect(x: 16, y: 130, width: 340, height: 48))
        var floating = element("staticText", FTRect(x: 0, y: 120, width: 375, height: 40), ref: 2)
        floating.label = "お知らせ"
        XCTAssertNil(TapTargetGeometry.uncoverScrollJump(
            target: target, coveredBy: floating, container: container))
        var narrow = element("staticText", FTRect(x: 0, y: 100, width: 120, height: 40), ref: 3)
        narrow.label = "新着"
        XCTAssertNil(TapTargetGeometry.uncoverScrollJump(
            target: target, coveredBy: narrow, container: container))
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

/// **キーボードに潜った対象の送り**(`uncoverKeyboardScrollJump` / `keyboardUncoverDragArea`)。
/// 帯用の判定(覆いが容器の半分以上・中心線のどちら側か)はキーボードに当てない
final class UncoverKeyboardScrollJumpTests: XCTestCase {
    private func field(_ rect: FTRect) -> ElementInfo {
        ElementInfo(ref: 1, type: "textView", identifier: nil, label: nil, value: nil,
                    placeholder: nil, enabled: true, frame: rect, depth: 2)
    }

    /// E2EX-CMP の入力画面・in-app の実測(容器 306..840・キーボード 541..874・欄 550..662)
    func testKeyboardTallerThanHalfAShortContainerIsStillLifted() {
        let container = FTRect(x: 0, y: 306, width: 402, height: 534)
        let keyboard = FTRect(x: 0, y: 541, width: 402, height: 333)
        let memo = field(FTRect(x: 16, y: 550, width: 370, height: 112))
        XCTAssertNil(TapTargetGeometry.uncoverScrollJump(target: memo, coveredBy: keyboard, container: container),
                     "前提: 帯用の判定ではこの形を送れない")
        XCTAssertEqual(TapTargetGeometry.uncoverKeyboardScrollJump(target: memo, keyboard: keyboard, container: container),
                       129)   // 662 − 541 + 8
        XCTAssertNil(TapTargetGeometry.uncoverDragArea(container: container, cover: keyboard),
                     "前提: 帯用の領域ではキーボードの下を選んで空になる")
        XCTAssertEqual(TapTargetGeometry.keyboardUncoverDragArea(container: container, keyboard: keyboard),
                       FTRect(x: 0, y: 306, width: 402, height: 235))
    }

    /// 背の高い容器(E2E-iOS の witness の形)では帯用と同じ量・同じ領域 = 既存の挙動を変えない
    func testTallContainerMatchesTheBandRule() {
        let container = FTRect(x: 0, y: 200, width: 402, height: 673)
        let keyboard = FTRect(x: 0, y: 573, width: 402, height: 301)
        let target = field(FTRect(x: 16, y: 600, width: 370, height: 44))
        XCTAssertEqual(TapTargetGeometry.uncoverKeyboardScrollJump(target: target, keyboard: keyboard, container: container),
                       TapTargetGeometry.uncoverScrollJump(target: target, coveredBy: keyboard, container: container))
        XCTAssertEqual(TapTargetGeometry.keyboardUncoverDragArea(container: container, keyboard: keyboard),
                       TapTargetGeometry.uncoverDragArea(container: container, cover: keyboard))
    }

    /// 送れない形: 対象がキーボードの上に出ている・送り量が容器の高さ以上・指を当てる領域が狭すぎる
    func testShapesThatCannotBeLifted() {
        let container = FTRect(x: 0, y: 306, width: 402, height: 534)
        let keyboard = FTRect(x: 0, y: 541, width: 402, height: 333)
        XCTAssertNil(TapTargetGeometry.uncoverKeyboardScrollJump(
            target: field(FTRect(x: 16, y: 400, width: 370, height: 64)), keyboard: keyboard, container: container))
        XCTAssertNil(TapTargetGeometry.uncoverKeyboardScrollJump(
            target: field(FTRect(x: 16, y: 600, width: 370, height: 600)), keyboard: keyboard, container: container))
        XCTAssertNil(TapTargetGeometry.keyboardUncoverDragArea(
            container: FTRect(x: 0, y: 450, width: 402, height: 400), keyboard: keyboard))
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
