import XCTest
import FTCore
@testable import FTFoundationModels

/// `FMReplayDelegate.healAttempt` の `elementText: String?` 分岐(2026-09-02 の直し)。
/// `LocatorRepairSuggestion.elementText` を非オプショナルのままにしていたため、モデルが
/// 「一覧に妥当な代わりが無い」と答える余地が無く、存在しない要素をわざと叩く陽性対照シナリオで
/// 無関係な要素を medium confidence で提案し続けていた(5周で完全再現)。
/// `elementText` が `nil` のとき `.noReplacement(rationale:)` を返すことをここで固定する。
/// `HealAttemptMappingTests.swift`(引き戻せる/引き戻せない elementText)とは別ファイルに置く ——
/// あちらは既存ファイルで、スキーマ変更に伴う追随以外は変更しない方針のため
final class HealAttemptNoReplacementMappingTests: XCTestCase {

    private func element(ref: Int, id: String?, label: String?) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10),
                    depth: 0)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 100, height: 100),
                         elements: elements, truncatedCount: 0)
    }

    /// **本題**: `elementText` が `nil` → `.noReplacement`。rationale が(整形を経て)乗ること。
    /// 「常に .proposed/.unresolved(決して .noReplacement を返さない)」変異が入っていたら、
    /// ここが落ちる
    func testNilElementTextReturnsNoReplacementWithMappedRationale() {
        let snap = snapshot([element(ref: 1, id: "nav_selector", label: "セレクタ")])
        let attempt = FMReplayDelegate.healAttempt(
            elementText: nil, confidence: .medium, rationale: "一致する要素がありません。", in: snap)

        guard case .noReplacement(let rationale) = attempt else {
            return XCTFail("elementText が nil のときは .noReplacement のはず: \(attempt)")
        }
        XCTAssertEqual(rationale, "一致する要素がありません。")
    }

    /// `nil` のときは一覧に要素が1つも無くても(=挟む要素すら無い画面でも)`.noReplacement` になり、
    /// `.unresolved`/`.proposed` に化けないこと
    func testNilElementTextReturnsNoReplacementEvenWithEmptySnapshot() {
        let snap = snapshot([])
        let attempt = FMReplayDelegate.healAttempt(
            elementText: nil, confidence: .low, rationale: "r", in: snap)

        guard case .noReplacement = attempt else {
            return XCTFail("空の木でも nil は .noReplacement のはず: \(attempt)")
        }
    }

    /// **陰性テスト**: `elementText` が non-nil(たとえ引き戻せない文字列でも)なら
    /// `.noReplacement` にはならない。「常に .noReplacement を返す」変異が入っていたら、
    /// ここが落ちる(HealAttemptMappingTests.swift が確認する `.unresolved`/`.proposed` と対)
    func testNonNilElementTextNeverReturnsNoReplacement() {
        let snap = snapshot([element(ref: 1, id: "btn_heal_v2", label: "修復対象")])

        let resolvable = FMReplayDelegate.healAttempt(
            elementText: "btn_heal_v2", confidence: .high, rationale: "r", in: snap)
        if case .noReplacement = resolvable {
            XCTFail("引き戻せる elementText を .noReplacement にしてはいけない: \(resolvable)")
        }

        let unresolvable = FMReplayDelegate.healAttempt(
            elementText: "存在しない要素", confidence: .high, rationale: "r", in: snap)
        if case .noReplacement = unresolvable {
            XCTFail("引き戻せない elementText(答えはある)を .noReplacement にしてはいけない: \(unresolvable)")
        }
    }
}
