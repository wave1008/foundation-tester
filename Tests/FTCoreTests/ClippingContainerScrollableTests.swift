// 容器推定(StepExecutor.clippingContainer)が **scrollable を申告する祖先を優先する**ことの固定。
//
// 受け手の最小再現(2026-08-23・iOS in-app、画面幅 402):
//   other d12 (0,432 402x199) scroll      ← 横カルーセル
//     clickable d13 (16,432 164x199)      ← カード1: staticText d16 レシートスタンプ / 未読
//     clickable d13 (188,432 164x199)     ← カード2
//     clickable d13 (360,432 164x199)     ← カード3(右にはみ出す): staticText d16 スタンプラリー / 未読
// 従来規則(同じ深さの子を2つ持つ直近の祖先)はカード3を容器に選び、画面と交差させた幅 42 が
// 要素幅 98 より小さい = 「viewport より大きい」扱いで見切れ判定が免除され、回復ドラッグに
// 入らないまま全画面スワイプが横カルーセルに届かず not-found になった。

import XCTest
@testable import FTCore

final class ClippingContainerScrollableTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func el(_ ref: Int, _ type: String, _ depth: Int, _ x: Double, _ y: Double,
                    _ w: Double, _ h: Double, label: String? = nil,
                    scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: x, y: y, width: w, height: h),
                    depth: depth, scrollable: scrollable)
    }

    /// 受け手の木そのもの(scrollable 申告あり)
    private func carouselTree(declaresScroll: Bool) -> [ElementInfo] {
        let scroll: Bool? = declaresScroll ? true : nil
        return [
            el(19, "clickable", 11, 0, 432, 402, 199),
            el(20, "other", 12, 0, 432, 402, 199, scrollable: scroll),
            el(21, "clickable", 13, 16, 432, 164, 199),
            el(22, "staticText", 16, 16, 563, 111, 20, label: "レシートスタンプ"),
            el(23, "staticText", 16, 16, 614, 30, 17, label: "未読"),
            el(24, "clickable", 13, 188, 432, 164, 199),
            el(25, "staticText", 16, 188, 563, 70, 20, label: "スマホくじ"),
            el(26, "staticText", 16, 188, 614, 30, 17, label: "未読"),
            el(27, "clickable", 13, 360, 432, 164, 199),
            el(28, "staticText", 16, 360, 563, 98, 20, label: "スタンプラリー"),
            el(29, "staticText", 16, 360, 614, 30, 17, label: "未読"),
        ]
    }

    /// 申告があるときは**カードではなく横カルーセル**が容器になる
    func testPrefersTheNearestScrollableAncestorOverTheCard() {
        let tree = carouselTree(declaresScroll: true)
        let target = tree[9]   // スタンプラリー
        XCTAssertEqual(StepExecutor.clippingContainer(of: target, in: tree, inferring: true),
                       FTRect(x: 0, y: 432, width: 402, height: 199))
        // その容器で見れば右縁の見切れとして判定される(= 回復ドラッグの分岐に入れる)
        let viewport = ScrollGeometry.intersection(
            StepExecutor.clippingContainer(of: target, in: tree, inferring: true)!, screen)!
        XCTAssertTrue(StepExecutor.isClippedByViewport(target, screen: viewport))
    }

    /// **縦リストの退行**(2026-08-28・iOS xcuitest 限定。maintainer-notes §4.5.1)。
    /// 行の容器 `#list_rows` は scrollable を申告せず、**外側の全画面 scrollView だけ**が申告する。
    /// 申告を無条件で優先すると容器が画面全体になり、慣性で動いている最中の見切れ・整定判定が
    /// 効かなくなって、行を移動前の座標で撃つ(`selected=-`)。
    /// **深さ由来の候補が申告容器の中で要素を収められるなら、そちらを採る**
    func testKeepsTheTighterRowContainerWhenOnlyTheOuterScrollViewDeclaresScroll() {
        let tree = [
            el(1, "scrollView", 1, 0, 0, 402, 874, scrollable: true),   // 全画面
            el(8, "other", 2, 16, 230, 370, 462),                       // #list_rows(申告なし)
            el(20, "button", 3, 16, 443, 370, 56, label: "行 30"),
            el(22, "button", 3, 16, 499, 370, 56, label: "行 31"),
        ]
        XCTAssertEqual(StepExecutor.clippingContainer(of: tree[2], in: tree, inferring: true),
                       FTRect(x: 16, y: 230, width: 370, height: 462),
                       "行を収められる #list_rows を容器にする(画面全体へ広げない)")
    }

    /// **動いている最中でも容器は変わらない**(2026-08-28)。慣性で動く木は一部の行を容器の外へ
    /// 報告するが、対象の行が容器に重なっている限り容器は変わらない
    func testKeepsTheRowContainerWhileOtherRowsAreReportedOutsideIt() {
        // 実測(失敗時の木): 送り出された行は容器(230..692)の外に報告され、残りは中に居る
        let tree = [
            el(1, "scrollView", 1, 0, 0, 402, 874, scrollable: true),
            el(8, "other", 2, 16, 230, 370, 462),
            el(20, "button", 3, 16, 60, 370, 56, label: "行 23"),    // 送り出されて容器の外
            el(21, "button", 3, 16, 116, 370, 56, label: "行 24"),   // 外
            el(22, "button", 3, 16, 275, 370, 56, label: "行 27"),   // 中
            el(23, "button", 3, 16, 443, 370, 56, label: "行 30"),   // 中(これが対象)
        ]
        XCTAssertEqual(StepExecutor.clippingContainer(of: tree[5], in: tree, inferring: true),
                       FTRect(x: 16, y: 230, width: 370, height: 462),
                       "容器の外に報告されていても #list_rows のまま(画面全体へ広げない)")
    }

    /// 逆向きの対照: 深さ由来の候補が**要素を収められない**なら申告容器へ倒す。
    /// カルーセルと同じ形を最小化したもの —— この向きを失うと 2026-08-23 の修正が戻る
    func testFallsBackToTheDeclaredScrollerWhenTheTightCandidateCannotHoldTheElement() {
        let tree = [
            el(1, "other", 1, 0, 432, 402, 199, scrollable: true),      // カルーセル
            el(2, "clickable", 2, 360, 432, 164, 199),                  // 右にはみ出すカード
            el(3, "staticText", 3, 360, 563, 98, 20, label: "スタンプラリー"),
            el(4, "staticText", 3, 360, 614, 30, 17, label: "未読"),
        ]
        XCTAssertEqual(StepExecutor.clippingContainer(of: tree[2], in: tree, inferring: true),
                       FTRect(x: 0, y: 432, width: 402, height: 199),
                       "カードは容器で切ると幅 42 で要素(98)を収められないので申告容器を採る")
    }

    /// 申告の無い木(Compose iOS の形)は従来の規則のまま = カードが容器(挙動を変えない)
    func testFallsBackToTheSiblingRuleWhenNothingDeclaresScroll() {
        let tree = carouselTree(declaresScroll: false)
        let target = tree[9]
        XCTAssertEqual(StepExecutor.clippingContainer(of: target, in: tree, inferring: true),
                       FTRect(x: 360, y: 432, width: 164, height: 199))
    }

    /// 申告が**より遠い祖先**にしか無くても、連鎖を辿って採る(間にある非スクロールの祖先で止まらない)
    func testWalksPastNonScrollingAncestorsToTheScroller() {
        var tree = carouselTree(declaresScroll: false)
        // 最上位(d11)に申告を付ける。d12 は無申告のまま
        tree[0] = el(19, "clickable", 11, 0, 432, 402, 199, scrollable: true)
        XCTAssertEqual(StepExecutor.clippingContainer(of: tree[9], in: tree, inferring: true),
                       FTRect(x: 0, y: 432, width: 402, height: 199))
    }

    /// containerInference を切ると申告があっても推定しない(利用者の殺しスイッチは最優先)
    func testInferenceSwitchStillWins() {
        let tree = carouselTree(declaresScroll: true)
        XCTAssertNil(StepExecutor.clippingContainer(of: tree[9], in: tree, inferring: false))
    }

    /// 祖先でない scrollable は採らない: **手前にある別の部分木の中の scrollable**(前のカードの内側、
    /// 深さは自分と同じか深い)と、**自分より後ろ**の scrollable(次の区画)。
    /// 祖先の連鎖は「手前に遡って depth が下がるたびに1段上」なので、depth の比較を外すと
    /// 手前のカードの内側の scrollable を掴んで別の容器で判定してしまう
    func testIgnoresScrollablesThatAreNotAncestors() {
        var tree = carouselTree(declaresScroll: false)
        // カード1の中に横スクロールのタグ列(depth 14 = 対象より浅いが祖先ではない)を入れる
        tree.insert(el(40, "other", 14, 16, 600, 164, 30, scrollable: true), at: 3)
        tree.append(el(30, "other", 12, 0, 700, 402, 223, scrollable: true))   // 次の区画
        let target = tree.first { $0.ref == 28 }!
        XCTAssertEqual(StepExecutor.clippingContainer(of: target, in: tree, inferring: true),
                       FTRect(x: 360, y: 432, width: 164, height: 199),
                       "手前の部分木や後ろの区画の scrollable を祖先と取り違えている")
    }
}
