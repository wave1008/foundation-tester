// 容器推定が**押し出し遷移の取り残し**(前の画面の要素)を新しい画面の行の容器にしないことの固定。
// 実測(M1Max・XCUITest・E2EY-iOS 58_戻るの横取り S0020): `tap #btn_open_editor` の直後の木 ——
//   [5] button #btn_open_editor d13 (-105,156 135x58)   ← 前の画面の取り残し(画面の左外)
//   [6] staticText #txt_editor_state d14 (16,122 81x16)
//   [7] textField #field_title d14 (16,156 370x34)      ← 角で交差
//   [8] button #btn_open_panel d14 (16,202 120x58)      ← 角で交差(14x12)・対象
// 旧実装は d13 のボタンを容器に選び、visibleTapRect が角 (23,208) を座標で撃ってパネルが開かなかった。

import XCTest
@testable import FTCore

final class ClippingContainerTransitionLeftoverTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ depth: Int, _ x: Double, _ y: Double,
                    _ w: Double, _ h: Double, id: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: x, y: y, width: w, height: h),
                    depth: depth)
    }

    private var pushTree: [ElementInfo] {
        [
            el(1, "navigationBar", 7, 0, 62, 402, 54, id: "編集"),
            el(2, "button", 10, 28, 66, 20, 36, id: "btn_back"),
            el(3, "staticText", 8, 185, 74, 32, 21),
            el(4, "staticText", 10, 185, 74, 32, 20, id: "txt_screen_title"),
            el(5, "button", 13, -105, 156, 135, 58, id: "btn_open_editor"),
            el(6, "staticText", 14, 16, 122, 81, 16, id: "txt_editor_state"),
            el(7, "textField", 14, 16, 156, 370, 34, id: "field_title"),
            el(8, "button", 14, 16, 202, 120, 58, id: "btn_open_panel"),
        ]
    }

    func testLeftoverOfThePushedAwayScreenIsNotTheContainer() {
        let tree = pushTree
        XCTAssertNil(ContainerGeometry.clippingContainer(of: tree[7], in: tree, inferring: true),
                     "行の中心を1件も収めない取り残し(d13)を容器にしない")
        XCTAssertNil(StepExecutor.visibleTapRect(for: tree[7], in: tree, inferring: true),
                     "容器が無ければ ref で撃つ(角を座標で撃たない)")
    }

    /// 行の中心を1件でも収める候補は従来どおり容器(縁にかかる行が混ざっていても)
    func testCandidateHoldingOneRowCentreStaysTheContainer() {
        let tree = [
            el(1, "other", 11, 0, 200, 390, 200, id: "wrap"),
            el(2, "button", 12, 16, 210, 358, 50, id: "row_1"),
            el(3, "button", 12, 16, 380, 358, 50, id: "row_straddle"),
        ]
        XCTAssertEqual(ContainerGeometry.clippingContainer(of: tree[2], in: tree, inferring: true),
                       FTRect(x: 0, y: 200, width: 390, height: 200))
    }
}
