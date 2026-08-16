// 打ち切りの逃げ道の共有判定(2026-08-15)。
//
// 直したのは「同じ画面で MCP と DSL が逆のことを言う」状態: DSL だけが
// 「対象に近づくようスクロールする」と勧めており、MCP は同じ事実に対して
// 「スクロールしても戻ってこない」と書いていた。**落ちた要素は配列から抜けている**ので
// MCP のほうが正しい。判定(どちらの手が残っているか)を1本にし、文言だけ呼び手ごとに持つ。
//
// **文言まで読む**(pass/fail では足りない): 主張を含む文が嘘になる周回は、単体テストが
// 緑のまま通る。ここでは「スクロールを勧めていないこと」「天井まで来ていたら上限を勧めない
// こと」を文字列で直接見る。

import XCTest
@testable import FTCore

final class SnapshotTruncationTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    /// `kept` は**予算ぶん**(各要素は一意な identifier)、`bulkExempt` は予算の外で届いた bulk 群。
    /// **bulk 群は分類器(`BridgeSnapshotThinning`)が実際に検知できる形で作る**(2026-08-15の
    /// budgetedCount 再実装で、申告値でなく配列を数え直すようになったため): 同一 identifier を
    /// `bulkGroupMinimum`(20)以上・非操作型・非スクロール容器。呼び出し側の bulkExempt は
    /// すべて20を超えるので閾値割れは無い
    private func snapshot(kept: Int, truncated: Int, bulkExempt: Int = 0) -> SnapshotResponse {
        let keptElements = (0..<kept).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: "e\(index)", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index), width: 10, height: 10), depth: 1)
        }
        let bulkElements = (0..<bulkExempt).map { index in
            ElementInfo(ref: kept + index + 1, type: "staticText", identifier: "bulk", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(kept + index), width: 10, height: 10), depth: 1)
        }
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: keptElements + bulkElements,
                                truncatedCount: truncated,
                                bulkExemptCount: bulkExempt > 0 ? bulkExempt : nil)
    }

    func testNoRemedyWhenNothingWasDropped() {
        XCTAssertNil(SnapshotTruncation.remedy(for: snapshot(kept: 10, truncated: 0)))
    }

    /// 既定(120)で切り詰められた木は、まだ上限を上げられる
    func testADefaultLimitReadCanStillRaiseTheLimit() {
        let remedy = SnapshotTruncation.remedy(for: snapshot(kept: 120, truncated: 60))
        XCTAssertEqual(remedy, .raiseLimit(to: 200), "落ちた分がちょうど入る値へ切り上げる")
    }

    /// **天井まで来ていたら「上げろ」と言わない** —— 言われたとおり上げても同じ木が返る
    func testACeilingReadIsNotToldToRaiseTheLimit() {
        let remedy = SnapshotTruncation.remedy(
            for: snapshot(kept: BridgeAPI.maxSnapshotElementsCeiling, truncated: 179))
        XCTAssertEqual(remedy, .narrowTheScreen)
    }

    /// **bulk 群で件数が天井を超えただけの木は「上げろ」と言う**(2026-08-15 のレビューで発見)。
    /// bulk 群は**予算の外**で送られる(安全弁は 400 件)ので、既定 120 で読んだ木でも
    /// `elements.count` は 500 を超え得る。`elements.count` をそのまま天井と比べると
    /// **上げれば取れる要素に「上げても無駄」と言う**
    func testABulkHeavyTreeReadAtTheDefaultLimitStillRaisesTheLimit() {
        let tree = snapshot(kept: BridgeAPI.maxSnapshotElements, truncated: 60, bulkExempt: 300)
        XCTAssertGreaterThan(tree.elements.count, BridgeAPI.maxSnapshotElementsCeiling,
                             "前提: 要素数だけなら天井を超えていること")
        XCTAssertFalse(SnapshotTruncation.isAtCeiling(tree), "予算ぶんは 120 なので天井ではない")
        XCTAssertEqual(SnapshotTruncation.remedy(for: tree), .raiseLimit(to: 200),
                       "bulk を予算に数えると、上げれば取れる要素を諦めさせる")
    }

    /// 逆側: **予算ぶんが天井に達していれば** bulk の有無に関わらず「上げろ」と言わない
    func testACeilingReadWithBulkIsStillNotToldToRaiseTheLimit() {
        let tree = snapshot(kept: BridgeAPI.maxSnapshotElementsCeiling, truncated: 10,
                            bulkExempt: 50)
        XCTAssertEqual(SnapshotTruncation.remedy(for: tree), .narrowTheScreen)
    }

    func testTheSuggestedLimitIsCappedAtTheCeiling() {
        XCTAssertEqual(SnapshotTruncation.suggestedLimit(snapshot(kept: 120, truncated: 5000)),
                       BridgeAPI.maxSnapshotElementsCeiling)
    }

    /// 上限未満の木でも下限は既定(120)。**既定を下回る値を勧めない**
    func testTheSuggestedLimitNeverGoesBelowTheDefault() {
        XCTAssertEqual(SnapshotTruncation.suggestedLimit(snapshot(kept: 2, truncated: 3)),
                       BridgeAPI.maxSnapshotElements)
    }

    // MARK: - budgetedCount は申告でなく配列から数え直す(2026-08-15)

    /// マージ形の生産者(in-app の WebView-DOM マージ)を模す: 申告 `bulkExemptCount` はマージ前
    /// (小さい)のままだが、配列にはマージ後の実 bulk 群(300件)が乗っている。
    /// **破ると落ちる**: 申告をそのまま引く旧実装は budgetedCount を過大(419)に見積もり、
    /// 天井(400)未満の木を narrowTheScreen(上げても無駄)と誤判定する
    func testMergedBulkGroupIsCountedFromTheArrayNotTheStaleDeclaration() {
        let kept = (0..<120).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: "e\(index)", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index), width: 10, height: 10), depth: 1)
        }
        let bulk = (0..<300).map { index in
            ElementInfo(ref: 121 + index, type: "staticText", identifier: "bulk", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(120 + index), width: 10, height: 10), depth: 1)
        }
        let tree = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: kept + bulk,
                                    truncatedCount: 60,
                                    // マージ前の申告(1件)。実配列には300件の bulk 群が乗っている
                                    bulkExemptCount: 1)
        XCTAssertEqual(SnapshotTruncation.budgetedCount(tree), 120,
                       "申告(1)でなく配列から数え直した bulk 件数(300)を引くこと")
        XCTAssertFalse(SnapshotTruncation.isAtCeiling(tree),
                       "予算ぶんは120で天井(400)未満なのに、古い申告を引くと419になり偽陽性になる")
        XCTAssertEqual(SnapshotTruncation.remedy(for: tree), .raiseLimit(to: 200),
                       "申告を信用すると narrowTheScreen(上げても無駄)という誤った案内になる")
    }

    /// 申告 nil(旧ブリッジ・Android)は bulk 免除の概念を持たず、同一 id 群があっても
    /// **予算を消費して**送っている。数え直すと過少カウントになるので、nil のときは
    /// 従来どおり `elements.count` をそのまま使う(分類器を当てない)
    func testNilDeclarationSkipsRecountEvenWhenTheArrayLooksBulkShaped() {
        let kept = (0..<50).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: "e\(index)", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index), width: 10, height: 10), depth: 1)
        }
        // 同一 id ×30(bulkGroupMinimum を超える)。だが Android は bulk 免除を持たないので、
        // これは(分類器の目には bulk 形でも)実際は予算を消費している要素
        let repeated = (0..<30).map { index in
            ElementInfo(ref: 51 + index, type: "staticText", identifier: "row", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(50 + index), width: 10, height: 10), depth: 1)
        }
        let tree = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: kept + repeated,
                                    truncatedCount: 0, bulkExemptCount: nil)
        XCTAssertEqual(SnapshotTruncation.budgetedCount(tree), tree.elements.count,
                       "nil のときは分類器を当てずそのまま数える")
    }

    /// 申告が実配列と一致する通常形(単一生成・マージなし)。**退行なし**の確認
    func testCorrectDeclarationMatchesTheRecountedValue() {
        let tree = snapshot(kept: 120, truncated: 60, bulkExempt: 50)
        XCTAssertEqual(SnapshotTruncation.budgetedCount(tree), 120)
    }

    // MARK: - 文言(主張が嘘にならないこと)

    /// **DSL がスクロールを勧めない**こと。これが元の食い違いそのもの
    func testTheDSLHintNeverSuggestsScrollingTowardsTheTarget() {
        for kept in [2, 120, BridgeAPI.maxSnapshotElementsCeiling] {
            let hint = StepExecutor.truncationHint(snapshot(kept: kept, truncated: 30))
            XCTAssertTrue(hint.contains("scrolling will not bring them back"), hint)
            XCTAssertFalse(hint.contains("scroll closer"), "空振りするスクロールを勧めている: \(hint)")
        }
    }

    /// **実行側が何をしたかを書かない**: 「天井で撮り直してある」と書くと、要素は見つかったが
    /// 覆われていた周回で嘘になる(撮り直すのは解決できなかったときだけ)
    func testTheDSLHintMakesNoClaimAboutWhatTheExecutorDid() {
        let hint = StepExecutor.truncationHint(snapshot(kept: 120, truncated: 30))
        XCTAssertFalse(hint.contains("retaken"), "実行側の挙動を主張している: \(hint)")
    }

    /// 天井まで来ていることは DSL の文言にも出る(読み手が同じ手を繰り返さないため)
    func testTheDSLHintSaysWhenTheCeilingWasAlreadyReached() {
        let atCeiling = StepExecutor.truncationHint(
            snapshot(kept: BridgeAPI.maxSnapshotElementsCeiling, truncated: 179))
        XCTAssertTrue(atCeiling.contains("\(BridgeAPI.maxSnapshotElementsCeiling)-element ceiling"),
                      atCeiling)
        let below = StepExecutor.truncationHint(snapshot(kept: 120, truncated: 30))
        XCTAssertFalse(below.contains("ceiling"),
                       "天井に達していないのに達したと書いている: \(below)")
    }

    // MARK: - 表示は budgetedCount を印字する(2026-08-15 のレビュー指摘)。bulk が乗った木で
    // 生の elements.count を印字すると、勧める上限(予算ぶんの120基準)より大きい数字が出て、
    // 読み手には矛盾として映る(例: "truncated at 420 elements" なのに
    // "read again with maxElements: 200")

    /// bulk 入りの木では budgetedCount を印字し、bulk の内訳句を添える。
    /// **破ると落ちる**: 表示を `snapshot.elements.count` に戻す変異は、この木で
    /// 420(=120+300)を印字するので "truncated at 120 elements" が一致しなくなる
    func testDSLHintPrintsBudgetedCountWithBulkBreakdownWhenBulkIsPresent() {
        let tree = snapshot(kept: 120, truncated: 60, bulkExempt: 300)
        let hint = StepExecutor.truncationHint(tree)
        let budgeted = SnapshotTruncation.budgetedCount(tree)
        XCTAssertEqual(budgeted, 120)
        XCTAssertTrue(hint.contains("truncated at 120 elements (plus 300 bulk-exempt elements"
                                    + " outside the budget);"), hint)
        // 不整合そのものの回帰: 印字した件数が勧める上限を超えていたら矛盾に見える
        XCTAssertLessThanOrEqual(budgeted, SnapshotTruncation.suggestedLimit(tree),
                                 "印字した件数が勧める上限を超えている(不整合): \(hint)")
    }

    /// bulk が無い木では内訳句が出ない(bulk==0 のとき出力がバイト単位で従来と同一である
    /// ことの裏返し —— budgetedCount == elements.count なので句が空なら自動的に一致する)
    func testDSLHintOmitsBulkBreakdownWhenThereIsNoBulk() {
        let tree = snapshot(kept: 120, truncated: 60)
        let hint = StepExecutor.truncationHint(tree)
        XCTAssertFalse(hint.contains("bulk-exempt"), hint)
        XCTAssertTrue(hint.contains("truncated at 120 elements;"), hint)
    }

    /// `ceilingTruncationEvidence`(3箇所目の表示)も同じ形にする
    func testCeilingTruncationEvidencePrintsBudgetedCountWithBulkBreakdown() {
        let tree = snapshot(kept: BridgeAPI.maxSnapshotElementsCeiling, truncated: 10,
                            bulkExempt: 50)
        let evidence = StepExecutor.ceilingTruncationEvidence(tree)
        XCTAssertTrue(evidence.contains("truncated at \(BridgeAPI.maxSnapshotElementsCeiling)"
                                        + " elements (plus 50 bulk-exempt elements outside the"
                                        + " budget)"), evidence)
    }

    // MARK: - bulkExemptPresentCount 単体

    /// 申告 nil(旧ブリッジ・Android)は0を返す
    func testBulkExemptPresentCountIsZeroWhenDeclarationIsNil() {
        let tree = snapshot(kept: 50, truncated: 0)
        XCTAssertNil(tree.bulkExemptCount)
        XCTAssertEqual(SnapshotTruncation.bulkExemptPresentCount(tree), 0)
    }

    /// bulk 群があるときは配列から数え直した実数を返す(budgetedCount と同じ分類器を経由)
    func testBulkExemptPresentCountRecountsFromTheArray() {
        let tree = snapshot(kept: 120, truncated: 60, bulkExempt: 300)
        XCTAssertEqual(SnapshotTruncation.bulkExemptPresentCount(tree), 300)
    }
}

/// 天井で撮り直すと解決できるようになる木を返すドライバ。
/// **1枚目は既定の上限で切り詰められ、対象が落ちている**
private final class TruncatingDriver: AppDriver {
    private(set) var reads = 0
    private var ceilingRequested = false

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        ceilingRequested = (max ?? 0) >= BridgeAPI.maxSnapshotElementsCeiling
    }

    func snapshot() async throws -> SnapshotResponse {
        reads += 1
        let filler = (0..<3).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: "filler\(index)",
                        label: nil, value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index) * 10, width: 10, height: 10), depth: 1)
        }
        guard ceilingRequested else {
            // 対象は「送られていないだけ」で実在する
            return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: filler,
                                    truncatedCount: 40)
        }
        let target = ElementInfo(ref: 99, type: "button", identifier: "submit", label: "送信",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 10, y: 200, width: 100, height: 40), depth: 1)
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: filler + [target],
                                truncatedCount: 0)
    }

    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

/// **肯定側も天井まで上げて撮り直す**(2026-08-15)。否定側だけ塞いであったため、
/// 実在する要素で赤くなる = flake が残っていた
final class PositivePathCeilingRetakeTests: XCTestCase {

    func testExistRetakesAtTheCeilingBeforeFailing() async {
        let driver = TruncatingDriver()
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "submit"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "切り詰めで落ちていた実在要素を「見つからない」と報告した: \(outcome.status)")
        XCTAssertGreaterThanOrEqual(driver.reads, 2, "天井で撮り直していない")
    }

    func testTapRetakesAtTheCeilingBeforeFailing() async {
        let driver = TruncatingDriver()
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "submit"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "切り詰めで落ちていた実在要素を解決できないと報告した: \(outcome.status)")
    }
}
