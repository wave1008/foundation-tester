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
                           scrollable: Bool? = nil,
                           insideScrollable: Bool = false) -> BridgeSnapshotThinning.Candidate {
        BridgeSnapshotThinning.Candidate(
            info: element(type, id: id, label: label, scrollable: scrollable),
            insideScrollable: insideScrollable)
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

    /// **スクロール容器の中の大群は bulk にしない**(長いリストは装飾ではない)。
    /// この場合はラベル持ち = tier1 なので、末尾から均等に落ちる
    func testGroupInsideScrollableIsNotBulk() {
        var candidates = (0..<90).map { i in
            candidate("other", id: "row", label: "行\(i)", insideScrollable: true)
        }
        candidates += (0..<30).map { i in candidate("staticText", label: "詳細\(i)") }

        let kept = BridgeSnapshotThinning.indicesToKeep(candidates, max: 40)

        XCTAssertEqual(kept.count, 40)
        // 同 tier では後ろから捨てるので、残るのは先頭40件
        XCTAssertEqual(kept, Array(0..<40))
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

    /// bulk を全部捨ててもまだ超過するなら tier2 → tier1 → tier0 の順に落ちる
    func testFallsThroughTiersWhenBulkIsNotEnough() {
        var candidates = (0..<20).map { _ in candidate("other", id: "pin") }   // tier3
        candidates += (0..<10).map { _ in candidate("other") }            // tier2
        candidates += (0..<10).map { _ in candidate("staticText", label: "t") }// tier1
        candidates += (0..<10).map { _ in candidate("button", label: "b") }    // tier0

        // 50 → 15: bulk 20 と tier2 10 を全部捨て、足りない5件を tier1 の後ろから削る。
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
}
