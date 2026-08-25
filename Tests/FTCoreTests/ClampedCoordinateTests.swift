// **座標が壊れている要素を解決候補にしない**ことを固定する。
//
// フレームワークは容器の可視域を外れた子孫の frame の原点を容器の原点へクランプする。
// XCUITest の `UITableView` では**実体化していない行のラベルまでツリーに載り**、全部が
// 容器の原点に積み上がる(2026-08-05 実採取: 40 行のうち 32 個が同一 frame・すべて depth 8)。
// 掴むと `tap("行 15")` が**先頭行をタップし**(可視性ガードを通らないので沈黙)、
// `exist("行 15")` は画面外なのに真を返す(「exist は非スクロール」の契約に反する)。
//
// **depth の一致を条件に入れるのが肝**: frame だけで判定すると、親子が同じ矩形を持つ
// 入れ子の連鎖(`homepage_container > main_content > list_container > recycler_view`)を
// 巻き込む。過去レポート 466 件へ当てて確認した誤検知がまさにこれだった。

import XCTest
@testable import FTCore

final class ClampedCoordinateTests: XCTestCase {

    /// 実採取の値をそのまま使う(容器 `#list_rows` は (16,270.33 370x395.33)・depth 6、
    /// 本物の先頭行ラベルは **x=36**、クランプ群は x=16 で depth 8)
    private func element(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil,
                         x: Double, y: Double, w: Double, h: Double, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    /// 実採取の木を縮めたもの: 可視の行1つ + そのラベル + 画面外の行ラベル3つ(同一 frame・同 depth)
    private func realWorldTree() -> [ElementInfo] {
        [element(5, "table", id: "list_rows", x: 16, y: 270.33, w: 370, h: 395.33, depth: 6),
         element(6, "clickable", id: "row_01", label: "行 01", x: 16, y: 270.33, w: 370, h: 56, depth: 7),
         element(7, "staticText", label: "行 01", x: 36, y: 270.33, w: 330, h: 56, depth: 8),
         element(28, "staticText", label: "行 12", x: 16, y: 270.33, w: 330, h: 56, depth: 8),
         element(29, "staticText", label: "行 13", x: 16, y: 270.33, w: 330, h: 56, depth: 8),
         element(30, "staticText", label: "行 14", x: 16, y: 270.33, w: 330, h: 56, depth: 8)]
    }

    // MARK: - 判定

    func testStackedSiblingsAreDetected() {
        let tree = realWorldTree()
        XCTAssertTrue(StepExecutor.hasClampedCoordinates(tree[3], in: tree), "積み上がった行 12")
        XCTAssertTrue(StepExecutor.hasClampedCoordinates(tree[5], in: tree), "積み上がった行 14")
    }

    /// **本物の先頭行ラベルは巻き込まない**(x が 20pt ずれる = 別の frame)
    func testTheRealRowIsNotDetected() {
        let tree = realWorldTree()
        XCTAssertFalse(StepExecutor.hasClampedCoordinates(tree[2], in: tree), "本物の 行 01 ラベル")
        XCTAssertFalse(StepExecutor.hasClampedCoordinates(tree[1], in: tree), "行 01 のセル")
    }

    /// **入れ子の連鎖は巻き込まない**。親子が同じ矩形を持つのは普通で、過去レポート 466 件へ
    /// 当てたときに実際に引っかかった形をそのまま使う(Flutter の app bar の連鎖)。
    ///
    /// **外側にもっと大きい容器が同じ原点で居る**のがこの形の要点 —— 「容器より小さい」条件だけでは
    /// 素通りできず、**depth が違う = 兄弟ではない**で初めて残る。
    /// この容器を外すと depth 条件を殺す変異が捕まらなくなる(2026-08-05 に変異検査で発見)
    func testNestingChainWithIdenticalFramesSurvives() {
        let chain = [
            element(1, "other", id: "homepage_container", x: 0, y: 0, w: 402, h: 874, depth: 3),
            element(2, "other", id: "app_bar", x: 0, y: 0, w: 402, h: 120, depth: 4),
            element(3, "other", id: "app_bar_container", x: 0, y: 0, w: 402, h: 120, depth: 5),
            element(4, "other", id: "homepage_app_bar_view", x: 0, y: 0, w: 402, h: 120, depth: 6),
        ]
        for node in chain {
            XCTAssertFalse(StepExecutor.hasClampedCoordinates(node, in: chain),
                           "入れ子の連鎖を壊れた座標と誤判定した: \(node.identifier ?? "?")")
        }
    }

    /// 親子2重(同 frame・違う depth)も残す。閾値3は同 depth の兄弟に対するもの
    func testParentAndChildSharingAFrameSurvive() {
        let pair = [element(1, "clickable", id: "cell", x: 0, y: 0, w: 100, h: 40, depth: 2),
                    element(2, "staticText", label: "行", x: 0, y: 0, w: 100, h: 40, depth: 3)]
        XCTAssertFalse(StepExecutor.hasClampedCoordinates(pair[0], in: pair))
        XCTAssertFalse(StepExecutor.hasClampedCoordinates(pair[1], in: pair))
    }

    /// 同 depth でも2つまでは残す(重なった装飾・オーバーレイを消さない)
    func testTwoSiblingsAtTheSameSpotSurvive() {
        let two = [element(1, "image", id: "bg", x: 0, y: 0, w: 100, h: 40, depth: 3),
                   element(2, "staticText", label: "文字", x: 0, y: 0, w: 100, h: 40, depth: 3)]
        XCTAssertFalse(StepExecutor.hasClampedCoordinates(two[0], in: two))
    }

    /// **全面に重ねたオーバーレイは3つ以上あっても残す**。これが「同じ場所に3つ」だけで
    /// 判定してはいけない理由 —— 症状で切ると既存テスト 13 件が落ちた。
    /// クランプは**容器の原点に固定されつつ容器より小さい**のが機構で、全面オーバーレイは
    /// 容器と同じ大きさになるためここで分かれる
    func testFullBleedOverlaysSurvive() {
        let stack = [
            element(1, "other", id: "box", x: 0, y: 0, w: 402, h: 874, depth: 2),
            element(2, "image", id: "bg", x: 0, y: 0, w: 402, h: 874, depth: 3),
            element(3, "other", id: "scrim", x: 0, y: 0, w: 402, h: 874, depth: 3),
            element(4, "other", id: "content", x: 0, y: 0, w: 402, h: 874, depth: 3),
        ]
        for node in stack.dropFirst() {
            XCTAssertFalse(StepExecutor.hasClampedCoordinates(node, in: stack),
                           "容器と同じ大きさの重なりを壊れた座標と誤判定した: \(node.identifier ?? "?")")
        }
    }

    /// 逆に、**容器より小さいまま原点に積み上がっていれば**クランプとみなす(実採取の形)
    func testSmallerThanTheContainerAndPinnedToItsOriginIsDetected() {
        let tree = realWorldTree()
        XCTAssertTrue(StepExecutor.hasClampedCoordinates(tree[4], in: tree))
        // **原点を貸している上位要素が1つも無ければ断定しない**(誤検知を出さない側へ倒す)。
        // 実採取の木では容器 `#list_rows` だけでなく `#row_01` のセルも原点を共有していて
        // (16,270.33 370x56 = 群より広い)、どちらでもクランプ先として成立する
        let orphan = tree.filter { $0.depth == 8 }
        XCTAssertFalse(StepExecutor.hasClampedCoordinates(orphan[1], in: orphan),
                       "クランプ先が居ないなら「ただの重なり」と読む")
    }

    // MARK: - 解決(候補から外す)

    /// **画面外の行はラベルで掴めない** = `exist` の契約(現在画面のみ判定)どおりになる
    func testClampedElementIsNotResolvable() {
        let tree = realWorldTree()
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: tree, truncatedCount: 0)
        XCTAssertNil(StepExecutor.match(FlowLocator(label: "行 12"), in: snapshot),
                     "座標が壊れた要素を掴むと、タップが先頭行へ落ちる")
        // 可視の行はこれまでどおり掴める(セルが優先される = pre-order で親が先)
        XCTAssertEqual(StepExecutor.match(FlowLocator(label: "行 01"), in: snapshot)?.identifier,
                       "row_01")
    }

    // MARK: - 殺しスイッチと防御

    /// **容器の推測に依存する補正は1つの環境変数で全部止められる**(`FT_CONTAINER_INFERENCE=off`)。
    /// 推測が外れる画面では、補正が**より悪い事態**を招き得る(別の場所を叩く・明後日へ送る・
    /// 正当な要素が候補から消える)ため、利用者が推測を持たなかった頃の挙動へ戻せるようにしておく
    func testContainerInferenceCanBeTurnedOff() {
        let tree = realWorldTree()
        // 入口(容器の推測)が止まる = 見切れ判定・掴み直し・座標補正が全部無効化される
        XCTAssertNotNil(StepExecutor.clippingContainer(of: tree[5], in: tree, inferring: true))
        XCTAssertNil(StepExecutor.clippingContainer(of: tree[5], in: tree, inferring: false))
        // 候補の除外も止まる
        XCTAssertTrue(StepExecutor.hasClampedCoordinates(tree[3], in: tree, inferring: true))
        XCTAssertFalse(StepExecutor.hasClampedCoordinates(tree[3], in: tree, inferring: false))
    }

    /// **細すぎる帯は撃たない**。容器の推測が外れていた場合、わずかな重なりを
    /// 「見えている部分」と信じて叩くと**より悪い場所**へ当たる
    func testThinSliverIsNotTapped() {
        let container = element(1, "other", id: "list", x: 16, y: 230, w: 370, h: 462, depth: 11)
        func row(_ ref: Int, _ y: Double, _ h: Double) -> ElementInfo {
            element(ref, "clickable", id: "row\(ref)", label: "行", x: 16, y: y, w: 370, h: h, depth: 12)
        }
        let inside1 = row(3, 300, 56), inside2 = row(4, 360, 56)
        // 可視部分が 3pt しかない(226..233 のうち 230..233)
        let sliver = row(2, 195, 38)
        XCTAssertNil(StepExecutor.visibleTapRect(for: sliver, in: [container, sliver, inside1, inside2]),
                     "3pt の帯を『見えている部分』として叩いてはいけない")
        // 実測の形(10pt 以上見えている)は従来どおり拾う
        let real = row(2, 206, 38)
        XCTAssertNotNil(StepExecutor.visibleTapRect(for: real, in: [container, real, inside1, inside2]))
    }

    // MARK: - 行き過ぎたら逆へ送る

    /// **通り過ぎた要素へは逆向きに送る**。探索方向のまま送り続けると遠ざかるだけで、
    /// 実測でも ghost 検出後の追加スワイプ2回が空振りした
    /// (注記に `3 re-resolve(s), 2 extra swipe(s)` が残り、`#row_30` は容器 230..692 の上 y=76 のまま)
    func testRecoveryReversesWhenTheTargetIsAlreadyPast() {
        let container = FTRect(x: 16, y: 230, width: 370, height: 462)
        let above = element(9, "button", id: "row_30", x: 16, y: 76, w: 370, h: 56, depth: 12)
        let below = element(9, "button", id: "row_30", x: 16, y: 800, w: 370, h: 56, depth: 12)
        // `withScrollDown` の指は上。行き過ぎた行は容器の**上**にあるので、指を下へ返す
        XCTAssertEqual(StepExecutor.recoveryDirection(for: above, container: container,
                                                      searching: .up), .down)
        // まだ届いていない側(容器の下)はこれまでどおり探索方向のまま
        XCTAssertEqual(StepExecutor.recoveryDirection(for: below, container: container,
                                                      searching: .up), .up)
    }

    /// 容器の中にある間は向きを変えない(= 通常の探索の挙動は不変)
    func testRecoveryKeepsTheSearchDirectionInsideTheContainer() {
        let container = FTRect(x: 16, y: 230, width: 370, height: 462)
        let inside = element(9, "button", id: "row_30", x: 16, y: 400, w: 370, h: 56, depth: 12)
        for finger in [FTSwipeDirection.up, .down, .left, .right] {
            XCTAssertEqual(StepExecutor.recoveryDirection(for: inside, container: container,
                                                          searching: finger), finger)
        }
    }

    /// 横方向も同じ規則(左へ行き過ぎたら指を右へ)
    func testRecoveryReversesHorizontally() {
        let container = FTRect(x: 16, y: 692, width: 370, height: 60)
        let left = element(9, "button", id: "tag_02", x: -120, y: 692, w: 120, h: 56, depth: 12)
        XCTAssertEqual(StepExecutor.recoveryDirection(for: left, container: container,
                                                      searching: .left), .right)
        let right = element(9, "button", id: "tag_20", x: 600, y: 692, w: 120, h: 56, depth: 12)
        XCTAssertEqual(StepExecutor.recoveryDirection(for: right, container: container,
                                                      searching: .left), .left)
    }

    /// **黙って消さない**。消したときは失敗文言で理由を説明する(でないと
    /// 「ツリーには在るのに見つからない」が読み解けない)
    func testFailureExplainsWhyItVanished() {
        let tree = realWorldTree()
        let hint = StepExecutor.clampedStackHint(for: FlowLocator(label: "行 12"), in: tree)
        XCTAssertNotNil(hint, "消した理由を書かないと調査できない")
        XCTAssertTrue(hint?.contains("stacked at the same spot") ?? false, "\(hint ?? "nil")")
        XCTAssertTrue(hint?.contains("scroll it into view") ?? false, "回避策を書くこと: \(hint ?? "nil")")
        // 正常な要素では出さない
        XCTAssertNil(StepExecutor.clampedStackHint(for: FlowLocator(label: "行 01"), in: tree))
    }
}
