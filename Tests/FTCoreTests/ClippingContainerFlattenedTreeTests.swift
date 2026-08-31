// 容器推定(StepExecutor.clippingContainer)が**間引かれた preorder 木で兄弟の見出しラベルを
// 親と誤認しない**ことの固定(実機 iPhone 13・2026-08-31)。
//
// 実機の木(アカウント画面、Compose):
//   [2]  other      id=screen_account d10 (0,47 390x683)
//   [3]  staticText "アカウント"       d11 (16,114 95x22)   ← 交差しない見出し
//   [7]  button     #btn_orders       d12 (16,270 358x56)
//   [22] button     #btn_logout       d12 (16,687 358x43)   ← 対象
// 旧実装(「直前の depth の小さい要素 = 親」)は #btn_logout の直前にある見出し「アカウント」
// (d11・95x22)を親と誤認する。見出しは同じ深さの行を1件も含まないので兄弟条件を満たせず nil に
// 落ち、`clippingContainer` がこの画面で丸ごと効かなくなっていた。

import XCTest
@testable import FTCore

final class ClippingContainerFlattenedTreeTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ depth: Int, _ x: Double, _ y: Double,
                    _ w: Double, _ h: Double, id: String? = nil, label: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: x, y: y, width: w, height: h),
                    depth: depth)
    }

    /// 実機の木そのもの。見出しを飛び越えて画面容器(d10)まで辿り着くこと
    func testWalksPastANonIntersectingHeadingToTheRealContainer() {
        let tree = [
            el(2, "other", 10, 0, 47, 390, 683, id: "screen_account"),
            el(3, "staticText", 11, 16, 114, 95, 22, label: "アカウント"),
            el(7, "button", 12, 16, 270, 358, 56, id: "btn_orders"),
            el(22, "button", 12, 16, 687, 358, 43, id: "btn_logout"),
        ]
        let logout = tree[3]
        XCTAssertEqual(StepExecutor.clippingContainer(of: logout, in: tree, inferring: true),
                       FTRect(x: 0, y: 47, width: 390, height: 683),
                       "見出し(交差しない d11)を飛び越えて画面容器(d10)を採ること")
    }

    /// 交差する d11 のラッパーで、中に同じ深さの兄弟が2つ以上 → 従来どおりラッパーを容器にする
    /// (交差する直近の祖先が最初に見つかったときの挙動は変えない)
    func testIntersectingWrapperWithTwoSiblingsIsUnchanged() {
        let tree = [
            el(1, "other", 11, 0, 200, 390, 200, id: "wrap"),
            el(2, "button", 12, 16, 210, 358, 50, id: "row_1"),
            el(3, "button", 12, 16, 270, 358, 50, id: "row_2"),
        ]
        let target = tree[2]
        XCTAssertEqual(StepExecutor.clippingContainer(of: target, in: tree, inferring: true),
                       FTRect(x: 0, y: 200, width: 390, height: 200))
    }

    /// 同じ深さの行を1件でも含む祖先が見つかったら、その中の兄弟が1つしか無くても nil ——
    /// **さらに上へは辿らない**。より上の祖先(outer)まで辿れば兄弟が2つ揃うが、
    /// 「行を含む祖先を1つ見つけたらそこで確定する」規律(2026-08-23 以前と同じ)をここで固定する
    func testStopsAtTheFirstIntersectingAncestorEvenWithOnlyOneSibling() {
        let tree = [
            el(1, "other", 10, 0, 0, 390, 400, id: "outer"),
            el(2, "other", 11, 0, 0, 390, 100, id: "wrap_a"),
            el(3, "button", 12, 16, 10, 358, 50, id: "row_x"),
            el(4, "other", 11, 0, 110, 390, 100, id: "wrap_b"),
            el(5, "button", 12, 16, 120, 358, 50, id: "target"),
        ]
        let target = tree[4]
        XCTAssertNil(StepExecutor.clippingContainer(of: target, in: tree, inferring: true),
                     "wrap_b は交差するが兄弟が1つだけ = nil。outer まで辿って兄弟2つに揃えてはいけない")
    }

    /// 祖先が1つも無い要素は nil
    func testElementWithNoAncestorsReturnsNil() {
        let tree = [el(1, "button", 0, 0, 0, 100, 40, id: "lone")]
        XCTAssertNil(StepExecutor.clippingContainer(of: tree[0], in: tree, inferring: true))
    }

    /// **ghost(容器の完全に外へ報告された行)の容器も引けること**。「要素と交差する祖先だけ」を
    /// gate にすると、容器と交差しない ghost は容器を失い `isOutsideContainer` が偽になる
    /// (ghost 検知が丸ごと死ぬ)。gate は「同じ深さの行を1件も含まない候補を飛ばす」だけ
    func testGhostRowOutsideItsContainerStillResolvesTheContainer() {
        let tree = [
            el(1, "scrollView", 1, 0, 230, 390, 462, id: "list_rows"),
            el(2, "cell", 2, 0, 240, 390, 60, id: "row_01"),
            el(3, "cell", 2, 0, 300, 390, 60, id: "row_02"),
            el(4, "cell", 2, 0, 783, 390, 60, id: "row_30"),
        ]
        let ghost = tree[3]
        XCTAssertEqual(StepExecutor.clippingContainer(of: ghost, in: tree, inferring: true),
                       FTRect(x: 0, y: 230, width: 390, height: 462),
                       "容器の外に居る行でも、行を2件以上含む容器は引けること(ghost 検知の前提)")
        XCTAssertTrue(StepExecutor.isOutsideContainer(
            ghost, in: tree, screen: FTRect(x: 0, y: 0, width: 390, height: 844)))
    }
}
