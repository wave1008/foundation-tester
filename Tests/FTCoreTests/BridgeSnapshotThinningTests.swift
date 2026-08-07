// 120件上限を超えたときに**何を先に捨てるか**を固定する(BridgeSnapshotThinning)。
//
// 実害(2026-08-07 実測・Apple マップ): 打ち切り画面は tier2 が 0 件で、枠の 75% を
// 同一 identifier の装飾ピン(`VKPointFeature` ×90)が占める。先着順でも Android の
// tier0〜2 でも落ちるのは preorder 末尾 = **詳細シートの中身**だった。
// bulk tier はこの「同じ id の大群」を最初に捨てる帯として足したもの。

import XCTest
@testable import FTCore

final class BridgeSnapshotThinningTests: XCTestCase {

    private func element(_ type: String, id: String? = nil, label: String? = nil,
                         scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: 0, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1,
                    scrollable: scrollable)
    }

    private func candidate(_ type: String, id: String? = nil, label: String? = nil,
                           scrollable: Bool? = nil) -> BridgeSnapshotThinning.Candidate {
        BridgeSnapshotThinning.Candidate(info: element(type, id: id, label: label, scrollable: scrollable))
    }

    /// 上限以下なら1件も落とさない(順序もそのまま)
    func testKeepsEverythingUnderTheCap() {
        let candidates = (0..<5).map { i in candidate("staticText", label: "t\(i)") }
        XCTAssertEqual(BridgeSnapshotThinning.indicesToKeep(candidates, max: 10), [0, 1, 2, 3, 4])
    }

    /// 装飾の大群(同一 id ×20以上・スクロール外・非操作)を最初に捨て、**中身が残る**。
    /// 実測画面の縮尺(ピン90 + 中身30 を上限40へ)
    func testBulkGroupIsDroppedBeforeContent() {
        var candidates = (0..<90).map { i in candidate("other", id: "VKPointFeature", label: "駅\(i)") }
        candidates += (0..<30).map { i in candidate("staticText", label: "詳細\(i)") }

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 40)

        XCTAssertEqual(kept.count, 40)
        // 中身(添字 90..119)は全部残る
        XCTAssertEqual(Array(kept.suffix(30)), Array(90..<120))
        // 残ったピンは先頭寄りの10件
        XCTAssertEqual(Array(kept.prefix(10)), Array(0..<10))
    }

    /// **58 で祖先ベースの bulk 免除を撤去**(地図 POI がスクロール容器[地図]の中に居るため
    /// 旧条件では素通りし、ラベル付き tier1 として本来操作可能な要素より後まで生き残っていた)。
    /// 同一 id 群は祖先の状況に関わらず bulk として最初に落ちる
    func testGroupWithScrollableAncestorIsNowBulk() {
        var candidates = (0..<90).map { i in candidate("other", id: "row", label: "行\(i)") }
        candidates += (0..<30).map { i in candidate("staticText", label: "詳細\(i)") }

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 40)

        XCTAssertEqual(kept.count, 40)
        // bulk(添字 0..89)から先に落ち、詳細(添字90..119)は全部残る
        XCTAssertEqual(Array(kept.suffix(30)), Array(90..<120))
        XCTAssertEqual(Array(kept.prefix(10)), Array(0..<10))
    }

    /// スクロール容器自身(info.scrollable == true)は同一 id が20件以上でも bulk(tier3)にならない
    func testScrollableCandidateIsNeverBulk() {
        let scrollableCandidate = candidate("other", id: "pane", scrollable: true)
        XCTAssertNotEqual(
            BridgeSnapshotThinning.tier(scrollableCandidate, identifierCounts: ["pane": 25]), 3)
    }

    /// tier0 まで落とす必要がある超過ツリーでも scrollable=true の要素は cap 免除で残る
    /// (結果が max を超えて返ることを許容する。indicesToKeep のコメント参照)
    func testScrollableContainerSurvivesCapEvenAtTier0() {
        var candidates = [candidate("other", id: "map1", scrollable: true),
                          candidate("other", id: "map2", scrollable: true)]
        candidates += (0..<3).map { i in candidate("button", label: "b\(i)") }

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 1)

        XCTAssertEqual(kept, [0, 1], "スクロール容器2件は max(1) を超えて残るはず")
    }

    /// 実害の再現形(2026-08-08 実測・Apple マップ)を縮尺: ラベルが全て異なる同一 id ×21・
    /// 非操作の群(地図 POI)は、祖先がスクロール容器でも bulk として最初に落ちる
    func testMapPOIGroupIsBulkDespiteScrollableAncestor() {
        var candidates = (0..<21).map { i in candidate("other", id: "VKPointFeature", label: "駅\(i)") }
        candidates += (0..<5).map { i in candidate("button", label: "詳細\(i)") }

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 5)

        XCTAssertEqual(kept, Array(21..<26))
    }

    /// POI 装飾群と隣り合うラベル付き同一id群が超過したとき、装飾(tier2)が先に落ちて
    /// ラベル付き bulk 群(tier3)が残ることを固定する(旧順序は bulk を先に落としていた)
    func testDecorativeTier2DropsBeforeALabeledBulkGroup() {
        var candidates = (0..<21).map { i in candidate("other", id: "row", label: "行\(i)") } // tier3(bulk)
        candidates += (0..<5).map { _ in candidate("other") } // tier2(ラベルもidも無い装飾)

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 22)

        // 装飾4件だけが落ち、ラベル付き bulk 群21件は無傷で残る
        XCTAssertEqual(kept, Array(0..<22))
    }

    /// 操作可能な型は大群でも bulk にしない(タップ対象を先に捨てない)
    func testOperableGroupIsNotBulk() {
        var candidates = (0..<90).map { i in candidate("button", id: "pin", label: "ピン\(i)") }
        candidates += (0..<30).map { i in candidate("staticText", label: "詳細\(i)") }

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 40)

        // ボタンは tier0・テキストは tier1 なので、捨てられるのはテキスト側
        XCTAssertEqual(kept, Array(0..<40))
    }

    /// 閾値未満(19件)の群は bulk にしない
    func testGroupBelowThresholdIsNotBulk() {
        var candidates = (0..<19).map { i in candidate("other", id: "pin", label: "ピン\(i)") }
        candidates += (0..<11).map { i in candidate("staticText", label: "詳細\(i)") }

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 25)

        // どちらも tier1 なので後ろから5件(= 詳細の末尾)が落ちる
        XCTAssertEqual(kept, Array(0..<25))
    }

    /// identifier が空の要素は群にまとめない(空文字で 20 件超えても bulk にならない)
    func testEmptyIdentifiersDoNotFormAGroup() {
        let candidates = (0..<30).map { _ in candidate("other") }
        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 10)
        // 全件 tier2(ラベルも id も無い)。末尾から落ちて先頭10件が残る
        XCTAssertEqual(kept, Array(0..<10))
    }

    /// tier2 と tier3(bulk)を両方捨ててもまだ超過するなら tier1 → tier0 の順に落ちる。
    /// この例は tier2(10)+tier3(20)=30 が必要な削減(35)に足りないため、両方全滅する点は
    /// 捨てる順序(tier2 が先か tier3 が先か)に依らず結果が同じ
    func testFallsThroughTiersWhenBulkIsNotEnough() {
        var candidates = (0..<20).map { _ in candidate("other", id: "pin") }   // tier3
        candidates += (0..<10).map { _ in candidate("other") }            // tier2
        candidates += (0..<10).map { _ in candidate("staticText", label: "t") }// tier1
        candidates += (0..<10).map { _ in candidate("button", label: "b") }    // tier0

        // 50 → 15: tier2 10 と bulk 20 を全部捨て、足りない5件を tier1 の後ろから削る。
        // tier0(操作可能)は最後まで無傷
        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 15)

        XCTAssertEqual(kept, Array(30..<35) + Array(40..<50))
    }

    /// **並べ替えない**(返る添字は常に昇順)。RefGuard.lineage が preorder+depth で
    /// ツリーを復元し、ref の大小を z-order の代理に使うため
    func testKeepsPreorder() {
        var candidates = (0..<30).map { _ in candidate("other", id: "pin") }   // 先頭が bulk
        candidates += (0..<10).map { _ in candidate("button", label: "b") }    // 末尾が tier0
        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 20)
        // 捨てた場所が飛び飛びでも、返るのは元の並びのまま(先頭のピン10 → 末尾のボタン10)
        XCTAssertEqual(kept, Array(0..<10) + Array(30..<40))
    }

    /// scrollable な容器自身は tier0(大群の一員でも先に捨てない)
    func testScrollableContainerIsTier0() {
        var candidates = [candidate("other", id: "list", scrollable: true)]
        candidates += (0..<30).map { _ in candidate("other", id: "pin") }
        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 5)
        XCTAssertTrue(kept.contains(0))
    }

    // MARK: - WebView DOM マージ(mergedSlots)

    /// 実測の実害(2026-08-08・E2E-iOS の密グリッドページ): 先着順カットは装飾セル 115 個を
    /// 残して**操作可能要素(送信ボタン・入力欄・リンク)を全部**押し出した。
    /// mergedSlots は同じ入力で操作可能要素を最後まで残す
    func testMergedSlotsKeepOperablesOverDecorativeTexts() {
        // native: コンテナ2 + 前後のボタン。DOM: 装飾テキスト30 + 末尾に button/textField
        let webView = ElementInfo(ref: 2, type: "webView", identifier: nil, label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 2)
        let base = [element("button", label: "back"), webView, element("button", label: "tab")]
        var dom = (0..<30).map { element("staticText", label: "C\($0)") }
        dom.append(element("button", label: "送信"))
        dom.append(element("textField", label: ""))
        let (kept, dropped) = BridgeSnapshotThinning.mergedSlots(
            base: base, dom: [2: dom], max: 10)
        XCTAssertEqual(dropped, 35 - 10)
        // 操作可能(native ボタン2 + DOM の button/textField)は全部残る
        XCTAssertTrue(kept.contains(.base(0)))
        XCTAssertTrue(kept.contains(.base(2)))
        XCTAssertTrue(kept.contains(.dom(container: 2, index: 30)), "送信ボタンが落ちた")
        XCTAssertTrue(kept.contains(.dom(container: 2, index: 31)), "入力欄が落ちた")
        // 捨てられるのは装飾テキストだけ(後ろから)
        XCTAssertTrue(kept.contains(.dom(container: 2, index: 0)))
        XCTAssertFalse(kept.contains(.dom(container: 2, index: 29)))
    }

    /// 上限以下なら合算順(ネイティブの直後に各コンテナの DOM)をそのまま返す
    func testMergedSlotsPreserveOrderUnderTheCap() {
        let webView = ElementInfo(ref: 1, type: "webView", identifier: nil, label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        let base = [webView, element("button", label: "tab")]
        let dom = [element("staticText", label: "a"), element("link", label: "l")]
        let (kept, dropped) = BridgeSnapshotThinning.mergedSlots(
            base: base, dom: [1: dom], max: 120)
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(kept, [.base(0), .dom(container: 1, index: 0),
                              .dom(container: 1, index: 1), .base(1)])
    }

    /// DOM の無い木では base がそのまま出る(マージ経路を通しても等価)
    func testMergedSlotsWithoutDOMAreJustTheBase() {
        let base = [element("button", label: "a"), element("staticText", label: "b")]
        let (kept, dropped) = BridgeSnapshotThinning.mergedSlots(base: base, dom: [:], max: 120)
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(kept, [.base(0), .base(1)])
    }
}
