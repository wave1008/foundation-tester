// `TapHitAreaMiss.activationPointMiss`(枠の中心が押せる範囲の外だと活性化の点から言い切れるか)と、
// それを使ってよいフレームワーク(`AppUIFramework.activationPointMarksHitArea`)を固定する。
// 値は E2EY-iOS の実測(maintainer-notes §77): 直す前の `.plain` の行は活性化の点が文字の上、直した後は中心。

import XCTest
@testable import FTCore

final class ActivationPointMissTests: XCTestCase {

    private func miss(_ ax: Double, _ ay: Double, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> TapHitAreaMiss? {
        TapHitAreaMiss.activationPointMiss(activationX: ax, activationY: ay, frameX: x, frameY: y, width: w, height: h)
    }

    /// 直す前の row_main_05: 枠 (0, 533.3, 402×74)・活性化の点 (44.3, 570.3) = 文字の上 → 中心は範囲の外
    func testPlainButtonRowWhoseShapeIsOnlyTheTextFires() {
        let result = miss(44.33, 570.33, 0, 533.33, 402, 74)
        XCTAssertEqual(result, TapHitAreaMiss(x: 201, y: 570.33, kind: .activationPoint(x: 44.33, y: 570.33)))
    }

    /// 縦方向だけ外れていても言う(片方の軸で届かなければ範囲の外)
    func testFiresOnTheVerticalAxisToo() {
        XCTAssertNotNil(miss(100, 105, 0, 100, 200, 100))
    }

    /// 直した後: 活性化の点 = 中心
    func testCentredActivationPointIsSilent() {
        XCTAssertNil(miss(201, 570.33, 0, 533.33, 402, 74))
    }

    /// SwiftUI の Toggle は 1.0pt ずれる(1 画素の許容なら発火していた)。範囲は中心に届きうるので黙る
    func testToggleOneOffPointIsSilent() {
        XCTAssertNil(miss(202, 222, 16, 200, 370, 44))
    }

    /// 文中リンク(活性化の点がリンクの上・中心から 40pt)も、外側 4 分の 1 に入らなければ言い切れないので黙る
    func testModerateOffsetInsideTheInnerHalfIsSilent() {
        XCTAssertNil(miss(150 + 40, 300, 0, 280, 300, 40))
    }

    /// 判定不能: 有限でない点(実測 `(inf, inf)` のメニューボタン)・枠の外の点・面積 0 の枠
    func testUndecidableInputsAreSilent() {
        XCTAssertNil(miss(.infinity, .infinity, 0, 0, 100, 40))
        XCTAssertNil(miss(.nan, 20, 0, 0, 100, 40))
        XCTAssertNil(miss(-10, 20, 0, 0, 100, 40))
        XCTAssertNil(miss(5, 5, 0, 0, 0, 40))
    }

    /// 使ってよいのは SwiftUI / UIKit だけ(RN の点は押せる範囲と無関係・自前描画は情報が無い)
    func testOnlySwiftUIAndUIKitActivationPointsMarkTheHitArea() {
        let expected: [AppUIFramework: Bool] = [.swiftUI: true, .uikit: true, .reactNative: false,
                                                .compose: false, .flutter: false, .androidView: false]
        for framework in AppUIFramework.allCases {
            XCTAssertEqual(framework.activationPointMarksHitArea, expected[framework], "\(framework)")
        }
    }

    /// in-app の dylib は swift test でリンクされないので、tapByRef の配線をソースで確かめる:
    /// フレームワークの門を読む(不明は黙る側)・activate の2経路(初回・取り直し)とも門を通す
    func testTapByRefGatesTheActivationPointOnTheFramework() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        XCTAssertTrue(bridge.contains("AppUIFramework(rawValue: uiFramework)?.activationPointMarksHitArea ?? false"),
                      "tapByRef が AppUIFramework.activationPointMarksHitArea を読んでいません(不明は黙る側)")
        XCTAssertEqual(bridge.components(separatedBy: "?? (activationPointMarksHitArea").count - 1, 2,
                       "activate の2経路(初回・取り直し)の両方で門を通すこと")
        XCTAssertTrue(bridge.contains("TapHitAreaMiss.activationPointMiss("),
                      "幾何は FTCore の純粋関数を使うこと(ブリッジに書き直さない)")
    }

}
