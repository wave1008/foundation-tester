import XCTest
import FTCore
@testable import FTFoundationModels

/// `FMReplayDelegate.healAttempt` は、FM の応答を受け取った**後**の写像だけを持つ純粋関数
/// (LanguageModelSession を呼ばない。入力は elementText/confidence/rationale の素の値と snapshot)。
/// `healLocator` はこの関数を呼ぶだけの薄いラッパで、FM 呼び出し自体は単体テストから通せないため、
/// 2026-09-02 の実測(「答えを要素へ引き戻せなかったら nil」という黙る経路)は
/// `healLocator` の中に判断が埋まっている限り単体テストで固定できなかった。
/// ここでは判断を純粋関数として直接叩き、`return nil` へ戻す変異(黙る経路の再発)が
/// 検出できることを固定する。
final class HealAttemptMappingTests: XCTestCase {

    private func element(ref: Int, id: String?, label: String?) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10),
                    depth: 0)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 100, height: 100),
                         elements: elements, truncatedCount: 0)
    }

    /// 引き戻せる elementText → `.proposed`。要素・confidence・rationale(整形後)がそのまま乗ること
    func testResolvableTextReturnsProposedWithMappedFields() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])
        let attempt = FMReplayDelegate.healAttempt(
            elementText: "btn_heal_v2", confidence: .high, rationale: "同じ役割です。", in: snap)

        guard case .proposed(let proposal) = attempt else {
            return XCTFail("引き戻せる答えは .proposed のはず: \(attempt)")
        }
        XCTAssertEqual(proposal.element.ref, 1)
        XCTAssertEqual(proposal.confidence, "high")
        XCTAssertEqual(proposal.rationale, "同じ役割です。")
    }

    /// confidence の写像(RepairConfidence → String)が high 以外でも正しいこと
    func testConfidenceMapsToItsStringForm() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])

        guard case .proposed(let medium) = FMReplayDelegate.healAttempt(
            elementText: "btn_heal_v2", confidence: .medium, rationale: "r", in: snap) else {
            return XCTFail("medium も .proposed のはず")
        }
        XCTAssertEqual(medium.confidence, "medium")

        guard case .proposed(let low) = FMReplayDelegate.healAttempt(
            elementText: "btn_heal_v2", confidence: .low, rationale: "r", in: snap) else {
            return XCTFail("low も .proposed のはず")
        }
        XCTAssertEqual(low.confidence, "low")
    }

    /// **本題**: 引き戻せない elementText → `.unresolved`。rawAnswer は入力の文字列と
    /// 完全一致すること(整形されない)。「常に .proposed(あるいは決して .unresolved を
    /// 返さない)」変異が入っていたら、ここが落ちる
    func testUnresolvableTextReturnsUnresolvedWithTheVerbatimRawAnswer() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])
        let rawAnswer = "戻るボタン(見当たらない)"
        let attempt = FMReplayDelegate.healAttempt(
            elementText: rawAnswer, confidence: .high, rationale: "r", in: snap)

        guard case .unresolved(let carried) = attempt else {
            return XCTFail("引き戻せない答えは .unresolved のはず: \(attempt)")
        }
        XCTAssertEqual(carried, rawAnswer, "生の答えは整形せずそのまま運ぶこと")
    }

    /// 空文字・`#` のような、剥がすと空になる入力でも `.unresolved` になること(nil ではない ——
    /// FM は答えている以上、この関数が「答えなし」を表現する余地を持たないことの確認)
    func testInputsThatStripToEmptyStillReturnUnresolvedNotNil() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])

        guard case .unresolved(let carried1) = FMReplayDelegate.healAttempt(
            elementText: "", confidence: .high, rationale: "r", in: snap) else {
            return XCTFail("空文字も .unresolved のはず")
        }
        XCTAssertEqual(carried1, "")

        guard case .unresolved(let carried2) = FMReplayDelegate.healAttempt(
            elementText: "#", confidence: .high, rationale: "r", in: snap) else {
            return XCTFail("# のみも .unresolved のはず")
        }
        XCTAssertEqual(carried2, "#")
    }
}
