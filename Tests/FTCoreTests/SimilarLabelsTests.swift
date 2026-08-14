// 「近いラベル/id を挙げる」候補選定(FTCore.SimilarLabels)と、その利用者である
// StepExecutor.candidateHint の回帰テスト。
//
// 2026-08-15: MCPServer+Hints.swift の similarLabelsHint(2026-08-10 に書き直された版)から
// FTCore へ降ろした。DSL 側の旧 candidateHint(部分文字列一致だけ・装飾葉を除かず・
// 文書順の先着3件)は、MCP が書き直す前に持っていたのと同じ欠陥形のまま残っていた。
// ここでは MCP 側の実測(Apple マップ・経路詳細: 装飾要素の POI が「南口」「北口」「1」を
// 出し、実在した操作ボタン「計画」を1件も出せなかった)と同じ形の木を作って固定する。
import XCTest
@testable import FTCore

private func node(_ ref: Int, type: String = "other", id: String? = nil,
                  label: String? = nil, depth: Int = 1) -> ElementInfo {
    ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                placeholder: nil, enabled: true,
                frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: depth)
}

private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                     elements: elements, truncatedCount: 0)
}

// MARK: - SimilarLabels(純粋関数)

final class SimilarLabelsTests: XCTestCase {

    func testIsSimilarTextCatchesSubstringRelationship() {
        XCTAssertTrue(SimilarLabels.isSimilarText("sign in", "Sign In Button"))
    }

    func testIsSimilarTextCatchesShortEditDistanceMatches() {
        XCTAssertTrue(SimilarLabels.isSimilarText("経路", "計画"))
    }

    func testIsSimilarTextStaysFalseForUnrelatedText() {
        XCTAssertFalse(SimilarLabels.isSimilarText("経路", "設定確認画面"))
        XCTAssertFalse(SimilarLabels.isSimilarText("経路", "経路"))
    }

    func testEditDistanceIsClassicLevenshtein() {
        XCTAssertEqual(SimilarLabels.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(SimilarLabels.editDistance("", "abc"), 3)
        XCTAssertEqual(SimilarLabels.editDistance("abc", "abc"), 0)
    }

    /// 装飾葉(bulk fold と同じ isDecorativeLeaf 判定)は候補プールから除く。
    /// **これが無いと**(=変異で除外条件を外すと)、次のテストの「操作可能ボタンを優先する」が
    /// 崩れる(装飾葉が先に埋まり得る)ので、単独でも壊れたら分かるように別に固定する
    func testCandidatesExcludeDecorativeLeaves() {
        let tree = snapshot([node(1, type: "other", label: "計画")]) // "計画" は "経路" と編集距離2
        XCTAssertTrue(SimilarLabels.candidates(labelTarget: "経路", idTarget: nil, in: tree).isEmpty)
    }

    /// 実測そのもの(Apple マップの経路詳細): 装飾葉の POI(「南口」「北口」「1」、いずれも
    /// "経路" と編集距離2以内)が文書順で先に並んでいても、操作可能なボタン「計画」を優先する
    func testCandidatesPreferOperableElementOverEarlierDecorativeLeaves() {
        let tree = snapshot([
            node(1, type: "other", label: "南口"),
            node(2, type: "other", label: "北口"),
            node(3, type: "other", label: "1"),
            node(4, type: "button", label: "計画"),
        ])
        let top = SimilarLabels.candidates(labelTarget: "経路", idTarget: nil, in: tree)
        XCTAssertEqual(top.first?.matchedText, "計画")
    }

    /// **同じ文字が複数の要素に出たときの取捨**。候補は一致した文字で1件に畳むので、
    /// どちらの要素を代表に採るかは畳む時点で決まる —— 文書順で先に出た装飾側ではなく
    /// **操作可能な方**を残す。上のテストは全部が別々の文字なのでこの分岐を1度も通らず、
    /// 「先着を採る」実装への退化を検出できなかった(2026-08-15 の変異で発覚)
    func testCandidatesKeepTheOperableElementWhenTheSameTextAppearsTwice() {
        let tree = snapshot([
            node(1, type: "staticText", label: "計画"),
            node(2, type: "button", label: "計画"),
        ])
        let top = SimilarLabels.candidates(labelTarget: "経路", idTarget: nil, in: tree)
        XCTAssertEqual(top.count, 1, "同じ文字は1件に畳む")
        XCTAssertEqual(top.first?.element.ref, 2, "文書順で後でも操作可能な方を代表に採る")
    }
}

// MARK: - StepExecutor.candidateHint(この選定の利用者)

final class CandidateHintTests: XCTestCase {

    /// **回帰テスト本体**: MCP の実測と同じ形の木で、DSL の失敗メッセージが
    /// 操作可能な「計画」ボタンを候補に出すこと・装飾葉の POI を出さないことを固定する。
    /// 旧 candidateHint(部分文字列一致・文書順の先着3件)ではこれが落ちる ——
    /// 「南口」「北口」「1」はいずれも "経路" と部分文字列関係が無い(旧実装は拾わない)ので
    /// 旧実装なら picked は空のまま「計画」も出せず、near matches 自体が付かなかった
    func testCandidateHintPrefersOperableButtonOverDecorativeLeaves() {
        let tree = snapshot([
            node(1, type: "other", label: "南口"),
            node(2, type: "other", label: "北口"),
            node(3, type: "other", label: "1"),
            node(4, type: "button", label: "計画"),
        ])
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "経路"), timeout: 0)
        let hint = StepExecutor.candidateHint(for: step, in: tree)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("計画"), hint!)
        XCTAssertFalse(hint!.contains("南口"), hint!)
        XCTAssertFalse(hint!.contains("北口"), hint!)
    }

    /// id の近さも同じ経路で拾う(部分文字列関係。SimilarLabels への置き換えで壊れやすい経路)
    func testCandidateHintStillFindsANearIdMatch() {
        let tree = snapshot([node(1, type: "button", id: "btn_submit", label: "送信")])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_submitt"), timeout: 0)
        let hint = StepExecutor.candidateHint(for: step, in: tree)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("btn_submit"), hint!)
    }

    /// **型による候補集めを落とさないこと**(SimilarLabels は id/ラベルの近さしか見ないので、
    /// id/ラベルどちらも無いロケータでは型一致に頼るしかない)。
    /// `.input` はエイリアスで textField/secureTextField へ展開される(FlowTypeAlias.expand)
    func testCandidateHintFallsBackToTypeMatchesWhenLocatorHasNoIdOrLabel() {
        let tree = snapshot([node(1, type: "textField", id: "search_box", label: nil)])
        let step = FlowStep(action: "tap", locator: FlowLocator(type: "input"), timeout: 0)
        let hint = StepExecutor.candidateHint(for: step, in: tree)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("search_box"), hint!)
    }

    /// 似た候補が何も無ければ黙る(id/ラベル/型のいずれも当たらない)
    func testCandidateHintStaysNilWithNoCandidate() {
        let tree = snapshot([node(1, type: "staticText", label: "設定確認画面")])
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "経路"), timeout: 0)
        XCTAssertNil(StepExecutor.candidateHint(for: step, in: tree))
    }
}
