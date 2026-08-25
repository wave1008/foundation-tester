import XCTest
@testable import FTCore

/// `SettleMotion` = 整定待ちを「時間予算」から「まだ減速しているか」へ載せ替える判定。
/// 待ちすぎ(等速アニメーションの画面で毎ジェスチャが上限まで待つ)と
/// 待たなすぎ(減速中に次へ進む = 2026-08-25 の横カルーセル 3/3 赤)の両方を固定する。
final class SettleMotionTests: XCTestCase {

    private func element(_ id: String?, label: String? = nil, type: String = "button",
                         x: Double, y: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: 10, height: 10), depth: 0)
    }

    // MARK: - displacement

    func testMeasuresTheLargestMoveAmongCommonElements() {
        let before = [element("a", x: 0, y: 0), element("b", x: 0, y: 100)]
        let after = [element("a", x: 0, y: -5), element("b", x: 0, y: 70)]
        XCTAssertEqual(SettleMotion.displacement(from: before, to: after), 30)
    }

    /// スクロールでは行が出入りする。**集合が変わること自体を動きと混同しない**
    /// (共通の要素だけで測る)
    func testRowsEnteringAndLeavingDoNotCountAsMovement() {
        let before = [element("a", x: 0, y: 0), element("gone", x: 0, y: 50)]
        let after = [element("a", x: 0, y: 0), element("new", x: 0, y: 900)]
        XCTAssertEqual(SettleMotion.displacement(from: before, to: after), 0)
    }

    /// 名前の無い要素は同一性が決まらないので数えない
    /// (装飾の staticText どうしを引き算して巨大な変位を捏造しない)
    func testUnnamedElementsAreIgnored() {
        let before = [element(nil, type: "staticText", x: 0, y: 0)]
        let after = [element(nil, type: "staticText", x: 0, y: 800)]
        XCTAssertNil(SettleMotion.displacement(from: before, to: after))
    }

    /// 同じ鍵が複数あるとどれと引き算するか決まらない。捨てる
    func testDuplicateKeysAreDropped() {
        let before = [element("dup", x: 0, y: 0), element("dup", x: 0, y: 50)]
        let after = [element("dup", x: 0, y: 400), element("dup", x: 0, y: 450)]
        XCTAssertNil(SettleMotion.displacement(from: before, to: after))
    }

    func testIdentifierIsPreferredOverLabelButLabelWorksAlone() {
        let before = [element(nil, label: "戻る", x: 0, y: 0)]
        let after = [element(nil, label: "戻る", x: 0, y: 12)]
        XCTAssertEqual(SettleMotion.displacement(from: before, to: after), 12)
    }

    /// 横方向も見る(横カルーセルがこの検査の発端)
    func testHorizontalMovementIsMeasured() {
        let before = [element("tag", x: 300, y: 0)]
        let after = [element("tag", x: 120, y: 0)]
        XCTAssertEqual(SettleMotion.displacement(from: before, to: after), 180)
    }

    // MARK: - isDecelerating

    /// 縮み続けている = フリングの減速。待つ
    func testShrinkingMovementKeepsWaiting() {
        XCTAssertTrue(SettleMotion.isDecelerating([180, 90, 40]))
        XCTAssertTrue(SettleMotion.isDecelerating([40, 1]))
    }

    /// 横ばい = 等速のアニメーション。待っても止まらないので抜ける
    func testSteadyMovementStopsWaiting() {
        XCTAssertFalse(SettleMotion.isDecelerating([20, 20, 20]))
    }

    /// 増加も減速ではない
    func testGrowingMovementStopsWaiting() {
        XCTAssertFalse(SettleMotion.isDecelerating([10, 30]))
    }

    /// 0 は止まった
    func testZeroMovementStopsWaiting() {
        XCTAssertFalse(SettleMotion.isDecelerating([50, 0]))
    }

    /// 1点では傾きが出ない。もう1周ぶんは待つ
    func testASingleSampleKeepsWaiting() {
        XCTAssertTrue(SettleMotion.isDecelerating([50]))
    }

    /// 履歴が空なら待たない(材料が無い)
    func testEmptyHistoryStopsWaiting() {
        XCTAssertFalse(SettleMotion.isDecelerating([]))
    }

    /// **判定不能(nil)は「動いている」側へ倒す** —— 共通要素が無いのは画面が入れ替わった
    /// 直後で、静止したと言える根拠が無い。**ただし1周だけ**(下のテスト)
    func testUnknownDisplacementKeepsWaiting() {
        XCTAssertTrue(SettleMotion.isDecelerating([nil]))
        XCTAssertTrue(SettleMotion.isDecelerating([30, nil]))
        XCTAssertTrue(SettleMotion.isDecelerating([nil, 30]))
        XCTAssertTrue(SettleMotion.isDecelerating([nil, nil, 30, nil]))
    }

    /// **2周続けて測れない画面は待たない**(名前を持つ要素が1つも無い画面。何周待っても
    /// 測れるようにはならないので、待ち続けると毎ジェスチャが上限まで回り切る)
    func testRepeatedlyUnknownDisplacementStopsWaiting() {
        XCTAssertFalse(SettleMotion.isDecelerating([nil, nil]))
        XCTAssertFalse(SettleMotion.isDecelerating([30, nil, nil]))
        XCTAssertFalse(SettleMotion.isDecelerating([nil, nil, nil, nil, nil, nil]))
    }
}
