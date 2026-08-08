// スナップショットの重複畳み(SnapshotDedupe)。
//
// 2026-08-06 の探索で iOS の AX ツリーが同じ物を2度出すことが分かった(Android は1つ)。
// 畳みすぎると**指せる要素が消える**ので、残す側の条件も一緒に固定する。

import XCTest
@testable import FTCore

final class SnapshotDedupeTests: XCTestCase {

    private func element(ref: Int, type: String = "Button", id: String? = nil,
                         label: String? = nil, value: String? = nil,
                         x: Double, y: Double, w: Double = 100, h: Double = 40,
                         scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: value,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 1,
                    scrollable: scrollable)
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

    // MARK: - wrapperScrollMerge (RN のラッパー分離。2026-08-08 実測)

    /// xcuitest 実測形: id 付きの Other + 匿名 scrollView。型が昇格して1要素に畳まれる
    func testWrapperScrollMergeUpgradesTypeFromXCUITestShape() {
        let a = element(ref: 1, type: "Other", id: "list_rows", x: 16, y: 251, w: 370, h: 431)
        let b = element(ref: 2, type: "ScrollView", id: nil, x: 16, y: 251, w: 370, h: 431,
                        scrollable: true)
        let merged = SnapshotDedupe.wrapperScrollMerge([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].identifier, "list_rows")
        XCTAssertEqual(merged[0].scrollable, true)
        XCTAssertEqual(merged[0].type, "scrollView")
    }

    /// in-app 実測形: 両方 Other。昇格する型が無いので type は変わらない
    func testWrapperScrollMergeKeepsTypeFromInAppShape() {
        let a = element(ref: 1, type: "Other", id: "list_rows", x: 16, y: 251, w: 370, h: 431)
        let b = element(ref: 2, type: "Other", id: nil, x: 16, y: 251, w: 370, h: 431,
                        scrollable: true)
        let merged = SnapshotDedupe.wrapperScrollMerge([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].identifier, "list_rows")
        XCTAssertEqual(merged[0].scrollable, true)
        XCTAssertEqual(merged[0].type, "other")
    }

    /// B にラベルがあると「別の情報を持つ要素」なので統合しない
    func testWrapperScrollMergeSkipsWhenBHasALabel() {
        let a = element(ref: 1, type: "Other", id: "list_rows", x: 16, y: 251, w: 370, h: 431)
        let b = element(ref: 2, type: "Other", id: nil, label: "何か", x: 16, y: 251, w: 370, h: 431,
                        scrollable: true)
        let merged = SnapshotDedupe.wrapperScrollMerge([a, b])
        XCTAssertEqual(merged.count, 2)
    }

    /// frame が許容(2pt)を超えてずれていると統合しない
    func testWrapperScrollMergeSkipsWhenFrameDrifts() {
        let a = element(ref: 1, type: "Other", id: "list_rows", x: 16, y: 251, w: 370, h: 431)
        let b = element(ref: 2, type: "Other", id: nil, x: 16, y: 254.1, w: 370, h: 431,
                        scrollable: true)
        let merged = SnapshotDedupe.wrapperScrollMerge([a, b])
        XCTAssertEqual(merged.count, 2)
    }

    /// A が既に scrollable なら A は候補から除外され、何も変わらない
    func testWrapperScrollMergeNoOpWhenAAlreadyScrollable() {
        let a = element(ref: 1, type: "Other", id: "list_rows", x: 16, y: 251, w: 370, h: 431,
                        scrollable: true)
        let b = element(ref: 2, type: "Other", id: nil, x: 16, y: 251, w: 370, h: 431,
                        scrollable: true)
        let merged = SnapshotDedupe.wrapperScrollMerge([a, b])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].type, "other")
        XCTAssertEqual(merged[0].frame, a.frame)
    }

    /// 前後に無関係な要素があっても順序は保たれる(A はその場でミューテート、B だけ穴が空く)
    func testWrapperScrollMergePreservesOrder() {
        let x = element(ref: 1, type: "Button", id: "btn_before", x: 0, y: 0)
        let a = element(ref: 2, type: "Other", id: "list_rows", x: 16, y: 251, w: 370, h: 431)
        let b = element(ref: 3, type: "Other", id: nil, x: 16, y: 251, w: 370, h: 431,
                        scrollable: true)
        let y = element(ref: 4, type: "Button", id: "btn_after", x: 0, y: 700)
        let merged = SnapshotDedupe.wrapperScrollMerge([x, a, b, y])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].identifier, "btn_before")
        XCTAssertEqual(merged[1].identifier, "list_rows")
        XCTAssertEqual(merged[1].scrollable, true)
        XCTAssertEqual(merged[2].identifier, "btn_after")
    }

    /// **隣接していない**同枠一致は統合しない(全画面 ScrollView と同寸の id 付きオーバーレイが
    /// 重なる形を誤結合しないため。RN のラッパー分離は常に隣接で出る)
    func testWrapperScrollMergeSkipsWhenBIsNotAdjacent() {
        let a = element(ref: 1, type: "Other", id: "list_rows", x: 16, y: 251, w: 370, h: 431)
        let c = element(ref: 2, type: "Button", id: "btn_other", x: 0, y: 0)
        let b = element(ref: 3, type: "Other", id: nil, x: 16, y: 251, w: 370, h: 431,
                        scrollable: true)
        let merged = SnapshotDedupe.wrapperScrollMerge([a, c, b])
        XCTAssertEqual(merged.count, 3)
        XCTAssertNotEqual(merged[0].scrollable, true)
    }

    // MARK: - isRedundant の scrollable ガード

    /// earlier が **id 持ち**・candidate が同型同枠で scrollable なら畳まない
    /// (wrapperScrollMerge の統合材料。畳むとスクロール可能性の情報が失われる)
    func testIsRedundantKeepsAScrollableTwinOfANonScrollableIdentifiedEarlier() {
        let earlier = element(ref: 1, type: "Other", id: "list_rows", x: 16, y: 251, w: 370, h: 431)
        let candidate = element(ref: 2, type: "Other", x: 16, y: 251, w: 370, h: 431,
                                scrollable: true)
        XCTAssertFalse(SnapshotDedupe.isRedundant(candidate, alreadyEmitted: [earlier]))
    }

    /// **匿名どうし**の同枠 scroll 双子は従来どおり畳む(広く残すと既存 SUT の序数と
    /// 間引き枠がずれる。ガードは id 持ち = 統合材料の形だけに絞る)
    func testIsRedundantStillDropsAnAnonymousScrollableTwin() {
        let earlier = element(ref: 1, type: "Other", x: 16, y: 251, w: 370, h: 431)
        let candidate = element(ref: 2, type: "Other", x: 16, y: 251, w: 370, h: 431,
                                scrollable: true)
        XCTAssertTrue(SnapshotDedupe.isRedundant(candidate, alreadyEmitted: [earlier]))
    }

    // MARK: - RN のテキスト2重化(in-app のみ。回帰固定)

    /// id 付き staticText + 同 frame・同ラベル・id 無しの匿名双子。既存ルールで落ちるはず
    func testRNDuplicateTextTwinIsDropped() {
        let first = element(ref: 1, type: "StaticText", id: "lbl_greeting", label: "こんにちは",
                            x: 24, y: 120, w: 200, h: 24)
        let second = element(ref: 2, type: "StaticText", id: nil, label: "こんにちは",
                             x: 24, y: 120, w: 200, h: 24)
        XCTAssertTrue(SnapshotDedupe.isRedundant(second, alreadyEmitted: [first]))
    }
}
