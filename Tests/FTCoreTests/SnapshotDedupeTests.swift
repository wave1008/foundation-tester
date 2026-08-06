// スナップショットの重複畳み(SnapshotDedupe)。
//
// 2026-08-06 の探索で iOS の AX ツリーが同じ物を2度出すことが分かった(Android は1つ)。
// 畳みすぎると**指せる要素が消える**ので、残す側の条件も一緒に固定する。

import XCTest
@testable import FTCore

final class SnapshotDedupeTests: XCTestCase {

    private func element(ref: Int, type: String = "Button", id: String? = nil,
                         label: String? = nil, value: String? = nil,
                         x: Double, y: Double, w: Double = 100, h: Double = 40) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: value,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
    }

    /// UIKit の Switch。**幅が 2pt ずれる**ラッパと実体で、内側は id を持たない
    func testTheUnnamedTwinOfASwitchIsDropped() {
        let outer = element(ref: 1, type: "Switch", id: "sw_notify", value: "0",
                            x: 56, y: 130, w: 61, h: 28)
        let inner = element(ref: 2, type: "Switch", id: nil, value: "0",
                            x: 56, y: 130, w: 63, h: 28)
        XCTAssertTrue(SnapshotDedupe.isRedundant(inner, alreadyEmitted: [outer]))
    }

    /// UIAlertController のボタンは**同じ id・同じ frame**で2つ来る
    func testAnExactTwinIsDropped() {
        let first = element(ref: 1, id: "btn_dialog_ok", label: "OK", x: 205, y: 450, w: 140, h: 48)
        let second = element(ref: 2, id: "btn_dialog_ok", label: "OK", x: 205, y: 450, w: 140, h: 48)
        XCTAssertTrue(SnapshotDedupe.isRedundant(second, alreadyEmitted: [first]))
    }

    /// **内側が名前を持つ形は落とさない**。落とすと指せる要素が消える
    func testANodeThatAddsAnIdentifierIsKept() {
        let outer = element(ref: 1, type: "Other", id: nil, x: 16, y: 100)
        let inner = element(ref: 2, type: "Other", id: "btn_real", x: 16, y: 100)
        XCTAssertFalse(SnapshotDedupe.isRedundant(inner, alreadyEmitted: [outer]))
    }

    func testANodeThatAddsALabelIsKept() {
        let outer = element(ref: 1, id: "cell", label: nil, x: 16, y: 100)
        let inner = element(ref: 2, id: "cell", label: "行 01", x: 16, y: 100)
        XCTAssertFalse(SnapshotDedupe.isRedundant(inner, alreadyEmitted: [outer]))
    }

    /// **型が違えば別物**。容器と中身(Other と Button)は今までどおり両方出す
    func testAContainerAndItsChildAreBothKept() {
        let container = element(ref: 1, type: "Other", id: "wrap", x: 16, y: 100)
        let button = element(ref: 2, type: "Button", id: nil, x: 16, y: 100)
        XCTAssertFalse(SnapshotDedupe.isRedundant(button, alreadyEmitted: [container]))
    }

    /// **同じ矩形へクランプされた行は畳まない**。あれは重複ではなく「描かれていない残骸」で、
    /// 畳むと `行 09`〜`行 40` が一覧から消えて、そこに何があるのかすら分からなくなる
    /// (扱いは MCP 側の ⚠️scroll-leftover 警告)
    func testClampedRowsWithDifferentLabelsAreAllKept() {
        let first = element(ref: 1, type: "StaticText", label: "行 09", x: 16, y: 270, w: 330, h: 56)
        let second = element(ref: 2, type: "StaticText", label: "行 10", x: 16, y: 270, w: 330, h: 56)
        XCTAssertFalse(SnapshotDedupe.isRedundant(second, alreadyEmitted: [first]))
    }

    /// 許容の外(3pt ずれ)は別の要素として残す
    func testAnElementJustOutsideTheToleranceIsKept() {
        let first = element(ref: 1, id: "a", x: 10, y: 10)
        let apart = element(ref: 2, id: "a", x: 10, y: 13.1)
        XCTAssertFalse(SnapshotDedupe.isRedundant(apart, alreadyEmitted: [first]))
    }

    /// value が違えば別物(同じ位置に別の状態が並ぶことはないが、畳んで状態を失わない側に倒す)
    func testADifferentValueIsKept() {
        let off = element(ref: 1, type: "Switch", id: "sw", value: "0", x: 10, y: 10)
        let on = element(ref: 2, type: "Switch", id: "sw", value: "1", x: 10, y: 10)
        XCTAssertFalse(SnapshotDedupe.isRedundant(on, alreadyEmitted: [off]))
    }
}
