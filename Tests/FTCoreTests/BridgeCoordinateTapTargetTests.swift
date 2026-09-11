// in-app の座標タップが activate する要素の選び方(BridgeCoordinateTapTarget.choose)。
// 数値は E2E-iOS のホーム画面の実測(スクロール容器 (0,156 402x622)・その下で切れた #nav_diagnostics
// (16,858 370x62)・タブ (0,778 134x62))。

import XCTest
import CoreGraphics
@testable import FTCore

final class BridgeCoordinateTapTargetTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 156, width: 402, height: 622)
    private let clippedRow = CGRect(x: 16, y: 858, width: 370, height: 62)

    /// 容器の外に出て描かれていない行は、frame が点を含んでも選ばない(名指し用には返す)
    func testRowOutsideItsScrollContainerIsNotChosen() {
        let choice = BridgeCoordinateTapTarget.choose(
            point: CGPoint(x: 201, y: 866), frames: [14: clippedRow], clips: [14: viewport])
        XCTAssertNil(choice.ref)
        XCTAssertEqual(choice.clippedRef, 14)
    }

    /// 同じ点に見えている要素があればそちらを選ぶ(切れた行は名指しだけ)
    func testVisibleLargerElementIsChosenOverAClippedSmallerOne() {
        let background = CGRect(x: 0, y: 0, width: 402, height: 874)
        let choice = BridgeCoordinateTapTarget.choose(
            point: CGPoint(x: 201, y: 866), frames: [14: clippedRow, 20: background],
            clips: [14: viewport])
        XCTAssertEqual(choice.ref, 20)
        XCTAssertEqual(choice.clippedRef, 14)
    }

    /// 一部だけ見えている行の、見えている部分を撃つのは正当
    func testVisiblePartOfAPartiallyClippedRowIsChosen() {
        let row = CGRect(x: 16, y: 740, width: 370, height: 62)   // 778 で切れる
        let choice = BridgeCoordinateTapTarget.choose(
            point: CGPoint(x: 201, y: 760), frames: [13: row], clips: [13: viewport])
        XCTAssertEqual(choice.ref, 13)
        XCTAssertNil(choice.clippedRef)
    }

    /// 容器の下端ちょうど(CGRect.contains は下端を含まない)でも見えている扱い
    func testPointExactlyOnTheClipEdgeCountsAsVisible() {
        let row = CGRect(x: 16, y: 740, width: 370, height: 62)
        let choice = BridgeCoordinateTapTarget.choose(
            point: CGPoint(x: 201, y: 778), frames: [13: row], clips: [13: viewport])
        XCTAssertEqual(choice.ref, 13)
    }

    /// 容器を祖先に持たない要素(clips に無い)は frame だけで判定する = 従来どおり最小面積
    func testElementsWithoutAClipKeepTheSmallestFrameRule() {
        let tabBar = CGRect(x: 0, y: 778, width: 402, height: 62)
        let tab = CGRect(x: 134, y: 778, width: 134, height: 62)
        let choice = BridgeCoordinateTapTarget.choose(
            point: CGPoint(x: 201, y: 800), frames: [1: tabBar, 2: tab], clips: [:])
        XCTAssertEqual(choice.ref, 2)
        XCTAssertNil(choice.clippedRef)
    }

    /// 切れた要素が選んだ要素より大きければ名指ししない(見えていても撃たれなかった要素)
    func testClippedElementLargerThanTheChosenOneIsNotNamed() {
        let tab = CGRect(x: 134, y: 778, width: 134, height: 62)
        let clippedHeal = CGRect(x: 16, y: 788, width: 370, height: 62)
        let choice = BridgeCoordinateTapTarget.choose(
            point: CGPoint(x: 201, y: 800), frames: [15: tab, 13: clippedHeal], clips: [13: viewport])
        XCTAssertEqual(choice.ref, 15)
        XCTAssertNil(choice.clippedRef)
    }

    /// 同じ面積なら ref の小さい方(辞書の走査順に依存しない)
    func testTieBreaksOnTheLowerRef() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let choice = BridgeCoordinateTapTarget.choose(
            point: CGPoint(x: 50, y: 50), frames: [7: a, 3: a, 5: a], clips: [:])
        XCTAssertEqual(choice.ref, 3)
    }
}
