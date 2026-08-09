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

    /// **bulk 群は上限の勘定に入らない**(61。2026-08-09)。実測画面の縮尺(ピン90 + 中身30 を
    /// 上限40へ)で、**中身30件が1件も押し出されず、ピンも捨てられない**こと。
    ///
    /// 60 までは「ピンを先に捨てて中身を残す」形だった。上限は「読み手が選ぶ対象」に
    /// 使い切らせるためのものなので、飾りは**捨てるのではなく予算の外へ出す**のが正しい ——
    /// 捨てると ref タップも expandBulk の展開もできなくなる
    func testBulkGroupDoesNotConsumeTheBudget() {
        var candidates = (0..<90).map { i in candidate("other", id: "VKPointFeature", label: "駅\(i)") }
        candidates += (0..<30).map { i in candidate("staticText", label: "詳細\(i)") }

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 40)

        // 予算が掛かるのは bulk 以外の30件だけ = 上限40に収まるので1件も落ちない
        XCTAssertEqual(kept, Array(0..<120))
        XCTAssertEqual(BridgeSnapshotThinning.bulkExemptCount(candidates), 90)
    }

    /// **58 で祖先ベースの bulk 免除を撤去**(地図 POI がスクロール容器[地図]の中に居るため
    /// 旧条件では素通りし、ラベル付き tier1 として本来操作可能な要素より後まで生き残っていた)。
    /// 同一 id 群は祖先の状況に関わらず bulk として最初に落ちる
    func testGroupWithScrollableAncestorIsNowBulk() {
        var candidates = (0..<90).map { i in candidate("other", id: "row", label: "行\(i)") }
        candidates += (0..<30).map { i in candidate("staticText", label: "詳細\(i)") }

        // 61 以降は bulk として**予算外**になる(60 までは「最初に捨てる」だった)
        XCTAssertEqual(BridgeSnapshotThinning.bulkExemptCount(candidates), 90)
        XCTAssertEqual(BridgeSnapshotThinning.indicesToKeep(candidates, max: 40), Array(0..<120))
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

        // 61: POI は予算外なので、ボタン5件が上限5に収まる限り**何も落ちない**
        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 5)

        XCTAssertEqual(kept, Array(0..<26))
    }

    /// bulk 群が予算外になったので、**残りの5件は上限22に収まり1件も落ちない**(61)。
    /// 60 までは「bulk 21件が枠を食い、装飾4件が落ちる」形だった —— 押し出しそのものが消えている
    func testNothingIsDroppedWhenOnlyBulkExceedsTheCap() {
        var candidates = (0..<21).map { i in candidate("other", id: "row", label: "行\(i)") } // bulk
        candidates += (0..<5).map { _ in candidate("other") } // tier2(ラベルもidも無い装飾)

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 22)

        XCTAssertEqual(kept, Array(0..<26))
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

    /// bulk が予算外になった後も、**残りの掃き出し順は tier2 → tier1 → tier0 のまま**(61)。
    /// 予算の対象は 30 件(tier2 10 + tier1 10 + tier0 10)で上限 15 なので 15 件落とす:
    /// tier2 を全部(10)+ tier1 の後ろから 5。tier0 は最後まで無傷で、bulk 20 は予算外なので全部残る
    func testFallsThroughTiersAfterBulkIsExempt() {
        var candidates = (0..<20).map { _ in candidate("other", id: "pin") }   // bulk(予算外)
        candidates += (0..<10).map { _ in candidate("other") }            // tier2
        candidates += (0..<10).map { _ in candidate("staticText", label: "t") }// tier1
        candidates += (0..<10).map { _ in candidate("button", label: "b") }    // tier0

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 15)

        XCTAssertEqual(kept, Array(0..<20) + Array(30..<35) + Array(40..<50))
    }

    /// **並べ替えない**(返る添字は常に昇順)。RefGuard.lineage が preorder+depth で
    /// ツリーを復元し、ref の大小を z-order の代理に使うため
    func testKeepsPreorder() {
        var candidates = (0..<30).map { _ in candidate("other", id: "pin") }   // 先頭が bulk(予算外)
        candidates += (0..<10).map { _ in candidate("staticText", label: "t") } // 末尾が tier1
        candidates += (0..<10).map { _ in candidate("button", label: "b") }     // さらに tier0
        // 予算の対象は 20 件で上限 12 → tier1 の後ろから 8 件落ちる。
        // 捨てた場所が飛び飛びでも、返るのは元の並びのまま
        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 12)
        XCTAssertEqual(kept, Array(0..<32) + Array(40..<50))
    }

    /// scrollable な容器自身は tier0(大群の一員でも先に捨てない)
    func testScrollableContainerIsTier0() {
        var candidates = [candidate("other", id: "list", scrollable: true)]
        candidates += (0..<30).map { _ in candidate("other", id: "pin") }
        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 5)
        XCTAssertTrue(kept.contains(0))
    }

    // MARK: - 捨てた分の内訳(SnapshotResponse.truncatedTiers)

    /// **件数だけでは方針を議論できない**(2026-08-09)。実測(Apple マップの経路プランナー)で
    /// 候補 211 → 120 の 91 件脱落を観測したが、「選べる物が消えたのか、飾りが消えただけか」が
    /// 分からず原因を断定できなかった
    func testDroppedByTierNamesWhatWasThrownAway() {
        var candidates = (0..<30).map { _ in candidate("Other") }                    // tier2
        candidates += (0..<25).map { _ in candidate("Other", id: "VKPointFeature") } // bulk(予算外)
        candidates += (0..<10).map { _ in candidate("Button", label: "OK") }         // tier0
        // 予算の対象は 40 件(tier2 30 + tier0 10)で上限 40 = **1件も落ちない**(61)。
        // 60 までは bulk 25 が枠を食って装飾 25 が落ちていた
        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 40)
        XCTAssertTrue(BridgeSnapshotThinning.droppedByTier(candidates, kept: kept).isEmpty)

        // 予算をさらに絞ると、落ちるのは従来どおり tier2 → tier1 → tier0 の順。
        // **bulk は予算外なので内訳に出ない**
        let deeper = BridgeSnapshotThinning.indicesToKeep(candidates, max: 20)
        let deeperDropped = BridgeSnapshotThinning.droppedByTier(candidates, kept: deeper)
        XCTAssertEqual(deeperDropped.values.reduce(0, +), candidates.count - deeper.count)
        XCTAssertEqual(deeperDropped["decoration"], 20)
        XCTAssertNil(deeperDropped["bulk"], "予算外の bulk が捨てられている: \(deeperDropped)")
        XCTAssertNil(deeperDropped["operable"], "操作可能要素は最後まで残る: \(deeperDropped)")
    }

    /// **天井を超えた分だけは捨てる**(安全弁。木が壊れたアプリで応答が無制限に膨らむのを防ぐ)。
    /// 捨てた分は内訳に "bulk" として出る = 黙って消えない
    func testBulkAboveTheCeilingIsDroppedAndReported() {
        let over = BridgeSnapshotThinning.bulkExemptCeiling + 30
        let candidates = (0..<over).map { i in candidate("other", id: "pin", label: "p\(i)") }

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 10)

        XCTAssertEqual(kept.count, BridgeSnapshotThinning.bulkExemptCeiling)
        XCTAssertEqual(BridgeSnapshotThinning.bulkExemptCount(candidates),
                       BridgeSnapshotThinning.bulkExemptCeiling)
        XCTAssertEqual(BridgeSnapshotThinning.droppedByTier(candidates, kept: kept)["bulk"], 30)
    }

    /// **天井が安全弁として機能する範囲にあること**。件数を定数から計算するテストだけだと、
    /// 天井を 100000 にする変異を素通しする(2026-08-09 の変異テストで実際に素通しした) ——
    /// 「無制限に膨らむのを防ぐ」という目的が失われたことを、値そのもので見る
    func testBulkCeilingStaysASafetyValve() {
        XCTAssertGreaterThanOrEqual(BridgeSnapshotThinning.bulkExemptCeiling, 100,
                                    "実測の最大(87)を下回ると、通常の地図画面で切り捨てが起きる")
        XCTAssertLessThanOrEqual(BridgeSnapshotThinning.bulkExemptCeiling, 1000,
                                 "安全弁として機能しない大きさ = 木が壊れたアプリで応答が膨らむ")
    }

    /// bulk の無い木では申告 0(「予算外で送った」と言わない)
    func testNoBulkMeansNoExemption() {
        let candidates = (0..<30).map { i in candidate("staticText", label: "t\(i)") }
        XCTAssertEqual(BridgeSnapshotThinning.bulkExemptCount(candidates), 0)
    }

    /// 上限に収まっているなら内訳は空(空の辞書を申告して「打ち切った」と読ませない)
    func testNothingDroppedGivesAnEmptyBreakdown() {
        let candidates = (0..<10).map { _ in candidate("Other") }
        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 120)
        XCTAssertTrue(BridgeSnapshotThinning.droppedByTier(candidates, kept: kept).isEmpty)
    }

    /// キーは tier 番号ではなく語彙(番号を外へ出すと、並びを変えた瞬間にホストの表示が嘘になる)
    func testTierKeysAreStableWords() {
        XCTAssertEqual(BridgeSnapshotThinning.tierKey(0), "operable")
        XCTAssertEqual(BridgeSnapshotThinning.tierKey(1), "labelled")
        XCTAssertEqual(BridgeSnapshotThinning.tierKey(2), "decoration")
        XCTAssertEqual(BridgeSnapshotThinning.tierKey(3), "bulk")
        XCTAssertEqual(Set(SnapshotResponse.truncatedTierOrder.map(\.key)),
                       ["operable", "labelled", "decoration", "bulk"],
                       "ホストの表示順と語彙が食い違っている")
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
