// Android の端送りのストロークを固定する(2026-08-20)。
// 端送りはブリッジの /swipe(画面比 0.4 + fling。実測 1本 約6行)ではなく
// 中央→端の drag(実測 1本 14行)で撃つ。往復回数がそのまま所要になるので、
// ここが弱いと長文の端送りが伸びる。**探索には使わない**(飛び越すため)。

import XCTest
import FTCore
@testable import FTAndroid

final class AndroidEdgeStrokeTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)

    /// 領域指定(scrollFrame)があるときは**ホストが計算した座標をそのまま使う** ——
    /// ここで作り直すと、指定した領域の外を動かす
    func testKeepsTheHostComputedPath() throws {
        let given = FTSwipePath(fromX: 100, fromY: 900, toX: 100, toY: 300)
        let path = try XCTUnwrap(AndroidDriver.edgeStroke(.up, path: given, screen: screen))
        XCTAssertEqual(path.fromY, 900)
        XCTAssertEqual(path.toY, 300)
    }

    /// 指定が無ければ中央→端。**画面の半分以上を動かす**こと(弱いストロークに戻さない)
    func testCentreToEdgeStrokeCoversMostOfTheScreen() throws {
        let up = try XCTUnwrap(AndroidDriver.edgeStroke(.up, path: nil, screen: screen))
        XCTAssertGreaterThan(up.fromY, up.toY, "指を上へ動かすこと(内容は下へ送られる)")
        XCTAssertGreaterThan(up.fromY - up.toY, screen.height * 0.35,
                             "ストロークが短い(/swipe の画面比 0.4 より弱いと意味が無い)")
        let down = try XCTUnwrap(AndroidDriver.edgeStroke(.down, path: nil, screen: screen))
        XCTAssertLessThan(down.fromY, down.toY, "向きが逆になっている")
    }

    /// 画面の大きさが分からないとき(snapshot 前)は nil = 従来の /swipe へ落ちる
    func testFallsBackWhenTheScreenIsUnknown() {
        XCTAssertNil(AndroidDriver.edgeStroke(.up, path: nil,
                                              screen: FTRect(x: 0, y: 0, width: 0, height: 0)))
    }
}

/// CDP で飛ばした結果の読み取り(純粋)。**「動かなかった」と読めたときだけ**端の確定を早める。
/// 読めない形を「動いていない」に倒すと、まだ途中なのに端と判断して止まる
final class AndroidScrollJumpReplyTests: XCTestCase {

    func testReadsWhetherThePageMoved() {
        XCTAssertTrue(AndroidWebViewDOM.scrollMoved("0|2255"), "動いたのに動いていないと読んでいる")
        XCTAssertFalse(AndroidWebViewDOM.scrollMoved("2255|2255"), "もう端なのに動いたと読んでいる")
        // 1px 未満のずれは動いていない扱い(小数の丸め)
        XCTAssertFalse(AndroidWebViewDOM.scrollMoved("2254.86|2255"))
    }

    /// **読めない形は「動いた」に倒す** —— 早く切り上げる側へ倒さない
    func testUnparseableRepliesCountAsMoved() {
        XCTAssertTrue(AndroidWebViewDOM.scrollMoved("none"))
        XCTAssertTrue(AndroidWebViewDOM.scrollMoved(""))
        XCTAssertTrue(AndroidWebViewDOM.scrollMoved("0|"))
    }
}
