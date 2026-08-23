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
