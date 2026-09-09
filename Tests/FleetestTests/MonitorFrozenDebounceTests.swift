// モニターの凍結判定(`MonitorFrozenDebounce`)。
//
// 判定の材料は監視ループが毎サイクル撮っている PNG で、一様フレーム = 画面凍結の症状。
// **1サンプルで凍結と言わない**のが要点 —— 起動直後・遷移中・全面が一色の画面は一瞬だけ
// 一様になる。run 前トリアージ(BlankWorkerTriage)が 1.5s 間隔で2連続を要求するのと同じ規律。

import XCTest
@testable import fleetest

final class MonitorFrozenDebounceTests: XCTestCase {

    func testOneBlankFrameIsNotFrozen() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        XCTAssertFalse(debounce.record(uniformBlank: true, id: "ios:01"))
        XCTAssertFalse(debounce.verdict(id: "ios:01").isFrozen)
    }

    func testTwoConsecutiveBlankFramesConfirmFrozen() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        XCTAssertTrue(debounce.record(uniformBlank: true, id: "ios:01"))
        XCTAssertTrue(debounce.verdict(id: "ios:01").isFrozen)
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
        XCTAssertFalse(debounce.verdict(id: "ios:01").isFrozen)
    }

    /// デバイスごとに独立(1台の凍結が他台の判定を汚さない)
    func testStreaksAreTrackedPerDevice() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.record(uniformBlank: true, id: "ios:02")
        debounce.record(uniformBlank: true, id: "ios:01")
        XCTAssertTrue(debounce.verdict(id: "ios:01").isFrozen)
        XCTAssertFalse(debounce.verdict(id: "ios:02").isFrozen, "02 はまだ1枚目")
    }

    /// **接続が切れたら忘れる** —— 落ちている機を凍結として数え続けない
    func testForgetDropsTheDeviceFromTheCount() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.forget(id: "ios:01")
        XCTAssertFalse(debounce.verdict(id: "ios:01").isFrozen)
        // 忘れた後は数え直し(1枚では確定しない)
        XCTAssertFalse(debounce.record(uniformBlank: true, id: "ios:01"))
    }

    /// 撮れなかったサイクルは record を呼ばない設計なので、**確定は保たれる**
    /// (呼び出し側の契約。ここでは「呼ばなければ変わらない」ことを固定する)
    func testSkippingACycleKeepsTheConfirmedState() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.record(uniformBlank: true, id: "ios:01")
        XCTAssertTrue(debounce.verdict(id: "ios:01").isFrozen)
        XCTAssertTrue(debounce.verdict(id: "ios:01").isFrozen)
    }

    /// 閾値1(即確定)でも壊れない。0 以下は1に丸める
    func testThresholdIsClampedToAtLeastOne() {
        var immediate = MonitorFrozenDebounce(confirmThreshold: 1)
        XCTAssertTrue(immediate.record(uniformBlank: true, id: "a"))
        var zero = MonitorFrozenDebounce(confirmThreshold: 0)
        XCTAssertTrue(zero.record(uniformBlank: true, id: "a"))
    }

    // MARK: - record(blankness:) — 判定不能(nil)の扱い

    /// 読めないフレーム(nil)を挟んでも、確定済みの凍結は取り消されない
    func testUndecodableFrameKeepsAConfirmedFreeze() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(uniformBlank: true, id: "ios:01")
        debounce.record(uniformBlank: true, id: "ios:01")
        XCTAssertTrue(debounce.verdict(id: "ios:01").isFrozen)
        XCTAssertTrue(debounce.record(blankness: nil, id: "ios:01"))
        XCTAssertTrue(debounce.verdict(id: "ios:01").isFrozen)
    }

    /// nil だけを何度撃っても確定しない(欠測は凍結の根拠にならない)
    func testUndecodableFramesAloneNeverConfirmAFreeze() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        XCTAssertFalse(debounce.record(blankness: nil, id: "ios:01"))
        XCTAssertFalse(debounce.record(blankness: nil, id: "ios:01"))
        XCTAssertFalse(debounce.record(blankness: nil, id: "ios:01"))
        XCTAssertFalse(debounce.verdict(id: "ios:01").isFrozen)
    }

    /// nil を挟んでも streak は数え直しにならない(撮れなかったサイクルと同じ扱い)
    func testUndecodableFrameDoesNotResetTheStreak() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        XCTAssertFalse(debounce.record(blankness: true, id: "ios:01"))
        debounce.record(blankness: nil, id: "ios:01")
        XCTAssertTrue(debounce.record(blankness: true, id: "ios:01"))
    }

    /// 逆方向の固定: 「読めて一様でない」(false)は従来どおり streak を消す
    /// (欠測(nil)と読めて一様でない(false)を混同しない)
    func testDecodedNonBlankFrameStillClearsTheStreak() {
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        debounce.record(blankness: true, id: "ios:01")
        XCTAssertFalse(debounce.record(blankness: false, id: "ios:01"))
        XCTAssertFalse(debounce.record(blankness: true, id: "ios:01"),
                       "false の後は数え直しになること")
    }
}
