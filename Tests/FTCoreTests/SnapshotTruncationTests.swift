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

    /// `kept` は**予算ぶん**、`bulkExempt` は予算の外で届いた bulk 群(要素配列には両方入る)
    private func snapshot(kept: Int, truncated: Int, bulkExempt: Int = 0) -> SnapshotResponse {
        let elements = (0..<(kept + bulkExempt)).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: "e\(index)", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index), width: 10, height: 10), depth: 1)
        }
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements,
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
