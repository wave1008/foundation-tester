// モニターの凍結判定(`MonitorFrozenDebounce`)。
//
// 判定の材料は監視ループが毎サイクル撮っている PNG で、一様フレーム = 画面凍結の症状。
// **1サンプルで凍結と言わない**のが要点 —— 起動直後・遷移中・全面が一色の画面は一瞬だけ
// 一様になる。run 前トリアージ(BlankWorkerTriage)が 1.5s 間隔で2連続を要求するのと同じ規律。

import XCTest
@testable import ftester

final class MonitorFrozenDebounceTests: XCTestCase {

    func testOneBlankFrameIsNotFrozen() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        XCTAssertFalse(debounce.record(uniformBlank: true, id: "ios:01"))
        XCTAssertFalse(debounce.isFrozen(id: "ios:01"))
        XCTAssertEqual(debounce.frozenCount, 0)
    }

    func testTwoConsecutiveBlankFramesConfirmFrozen() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        XCTAssertTrue(debounce.record(uniformBlank: true, id: "ios:01"))
        XCTAssertTrue(debounce.isFrozen(id: "ios:01"))
        XCTAssertEqual(debounce.frozenCount, 1)
    }

    /// **連続していなければ確定しない**(1枚おきに一様になる画面を凍結と呼ばない)
    func testBlankStreakResetsOnANonBlankFrame() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.record(uniformBlank: false, id: "ios:01")
        XCTAssertFalse(debounce.record(uniformBlank: true, id: "ios:01"),
                       "間に非一様が入ったら数え直すこと")
    }

    /// 復帰は**1枚で**(凍結の解除を遅らせない)
    func testOneNonBlankFrameClearsAConfirmedFreeze() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.record(uniformBlank: true, id: "ios:01")
        XCTAssertFalse(debounce.record(uniformBlank: false, id: "ios:01"))
        XCTAssertEqual(debounce.frozenCount, 0)
    }

    /// デバイスごとに独立(1台の凍結が他台の判定を汚さない)
    func testStreaksAreTrackedPerDevice() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.record(uniformBlank: true, id: "ios:02")
        debounce.record(uniformBlank: true, id: "ios:01")
        XCTAssertTrue(debounce.isFrozen(id: "ios:01"))
        XCTAssertFalse(debounce.isFrozen(id: "ios:02"), "02 はまだ1枚目")
        XCTAssertEqual(debounce.frozenCount, 1)
    }

    /// **接続が切れたら忘れる** —— 落ちている機を凍結として数え続けない
    func testForgetDropsTheDeviceFromTheCount() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.forget(id: "ios:01")
        XCTAssertFalse(debounce.isFrozen(id: "ios:01"))
        XCTAssertEqual(debounce.frozenCount, 0)
        // 忘れた後は数え直し(1枚では確定しない)
        XCTAssertFalse(debounce.record(uniformBlank: true, id: "ios:01"))
    }

    /// 撮れなかったサイクルは record を呼ばない設計なので、**確定は保たれる**
    /// (呼び出し側の契約。ここでは「呼ばなければ変わらない」ことを固定する)
    func testSkippingACycleKeepsTheConfirmedState() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.record(uniformBlank: true, id: "ios:01")
        XCTAssertTrue(debounce.isFrozen(id: "ios:01"))
        XCTAssertTrue(debounce.isFrozen(id: "ios:01"))
    }

    /// 閾値1(即確定)でも壊れない。0 以下は1に丸める
    func testThresholdIsClampedToAtLeastOne() {
        var immediate = MonitorFrozenDebounce(confirmThreshold: 1)
        XCTAssertTrue(immediate.record(uniformBlank: true, id: "a"))
        var zero = MonitorFrozenDebounce(confirmThreshold: 0)
        XCTAssertTrue(zero.record(uniformBlank: true, id: "a"))
    }
}
