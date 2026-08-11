import XCTest
@testable import FTCore

/// 凍結判定の型そのもの。**根拠ごとの強さ**(単独で確定してよいか)と、
/// 注入だけの状態がデバイスを触る動作を誘発しないことを固定する
final class FrozenVerdictTests: XCTestCase {

    func testHealthyHasNoEvidence() {
        XCTAssertFalse(FrozenVerdict.healthy.isFrozen)
        XCTAssertFalse(FrozenVerdict.healthy.isSuspected)
        XCTAssertEqual(FrozenVerdict.healthy.summary, "")
    }

    func testUniformBlankIsConclusive() {
        let verdict = FrozenVerdict([.uniformBlank])
        XCTAssertTrue(verdict.isFrozen)
        XCTAssertFalse(verdict.isSuspected)
    }

    /// **未検証の根拠は単独で確定させない**(警告から始める規律)。
    /// 実デバイスで「凍結時に拍動が止まる」を確認したら isConclusive を true にする
    func testNoPresentAloneIsSuspectedButNotConfirmed() {
        let verdict = FrozenVerdict([.noPresent])
        XCTAssertFalse(verdict.isFrozen, "拍動だけで凍結と断じてはいけない")
        XCTAssertTrue(verdict.isSuspected)
    }

    /// 弱い根拠は強い根拠と併せれば確定する(合流の意味)
    func testNoPresentWithBlankIsConfirmed() {
        XCTAssertTrue(FrozenVerdict([.noPresent, .uniformBlank]).isFrozen)
    }

    func testInjectedOnlyIsFrozenButNotActionable() {
        let verdict = FrozenVerdict([.injected])
        XCTAssertTrue(verdict.isFrozen, "表示はする")
        XCTAssertTrue(verdict.isInjectedOnly, "回復・除外は撃たない")
    }

    /// 実体の根拠が混じったら注入だけではない = デバイスを触ってよい
    func testInjectedWithRealEvidenceIsActionable() {
        XCTAssertFalse(FrozenVerdict([.injected, .uniformBlank]).isInjectedOnly)
    }

    /// 重複除去と整列(JSON のバイト安定性。同じ状態が毎回同じ内容で書かれること)
    func testEvidenceIsNormalized() {
        let a = FrozenVerdict([.injected, .uniformBlank, .injected])
        let b = FrozenVerdict([.uniformBlank, .injected])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.evidence, [.uniformBlank, .injected], "CaseIterable の宣言順で並ぶ")
    }

    func testMergedUnionsEvidence() {
        let merged = FrozenVerdict([.uniformBlank]).merged(with: FrozenVerdict([.injected]))
        XCTAssertEqual(merged.evidence, [.uniformBlank, .injected])
    }

    func testMergedWithHealthyKeepsEvidence() {
        XCTAssertEqual(FrozenVerdict([.uniformBlank]).merged(with: .healthy),
                       FrozenVerdict([.uniformBlank]))
    }

    func testCodableRoundTrip() throws {
        let verdict = FrozenVerdict([.uniformBlank, .noPresent])
        let data = try JSONEncoder().encode(verdict)
        XCTAssertEqual(try JSONDecoder().decode(FrozenVerdict.self, from: data), verdict)
    }

    // MARK: - 注入(陽性対照の口)

    func testInjectionParsesCommaSeparatedKeys() {
        let env = [FrozenInjection.environmentKey: " udid-a , emulator-5554 ,, "]
        XCTAssertEqual(FrozenInjection.keys(environment: env), ["udid-a", "emulator-5554"])
    }

    func testInjectionMatchesOnlyListedKeys() {
        let env = [FrozenInjection.environmentKey: "udid-a"]
        XCTAssertTrue(FrozenInjection.isInjected(key: "udid-a", environment: env))
        XCTAssertFalse(FrozenInjection.isInjected(key: "udid-b", environment: env))
    }

    /// **キーを持たない対象へ暴発させない**(nil/空で全台凍結になると対照実験が成立しない)
    func testInjectionNeverAppliesWithoutKey() {
        let env = [FrozenInjection.environmentKey: "udid-a"]
        XCTAssertFalse(FrozenInjection.isInjected(key: nil, environment: env))
        XCTAssertFalse(FrozenInjection.isInjected(key: "", environment: env))
    }

    func testInjectionAbsentByDefault() {
        XCTAssertTrue(FrozenInjection.keys(environment: [:]).isEmpty)
        XCTAssertFalse(FrozenInjection.isInjected(key: "udid-a", environment: [:]))
    }

    // MARK: - 観測から判定を組み立てる(run とモニターの共通規則)

    /// **本丸**(2026-08-11 の実測): 一様でも拍動が生きていれば凍結ではない。
    /// フル E2E で凍結と判定された 13台は 13台とも拍動が生きており、台数は描画の重さに
    /// 比例した(Flutter 10 / Compose 3 / SwiftUI・RN 0)= アプリの初回描画待ちだった
    func testUniformFrameWithLiveDisplayIsNotFrozen() {
        let verdict = FrozenVerdict.observe(uniformBlank: true, displayIdleSeconds: 0.05)
        XCTAssertFalse(verdict.isFrozen, "初回描画待ちでフリートを再起動してはいけない")
        XCTAssertTrue(verdict.evidence.isEmpty)
    }

    /// 拍動が止まっていれば従来どおり凍結(根拠は2つ揃う)
    func testUniformFrameWithStalledDisplayIsFrozen() {
        let verdict = FrozenVerdict.observe(uniformBlank: true, displayIdleSeconds: 30)
        XCTAssertTrue(verdict.isFrozen)
        XCTAssertEqual(verdict.evidence, [.uniformBlank, .noPresent])
    }

    /// **申告が無いときは保護を外さない**(旧ブリッジ・ブリッジ無しの機を見逃さない)
    func testUniformFrameWithoutHeartbeatStaysFrozen() {
        XCTAssertTrue(FrozenVerdict.observe(uniformBlank: true, displayIdleSeconds: nil).isFrozen)
    }

    /// 一様でなく拍動だけ止まっているのは**疑いどまり**(単独では確定させない)
    func testStalledDisplayAloneIsOnlySuspected() {
        let verdict = FrozenVerdict.observe(uniformBlank: false, displayIdleSeconds: 30)
        XCTAssertFalse(verdict.isFrozen)
        XCTAssertTrue(verdict.isSuspected)
    }

    /// 健全(一様でない・拍動も生きている)
    func testHealthyObservation() {
        XCTAssertEqual(FrozenVerdict.observe(uniformBlank: false, displayIdleSeconds: 0.05), .healthy)
    }

    /// 注入は観測に優先する(陽性対照が他の根拠に埋もれない)
    func testInjectionWins() {
        XCTAssertEqual(FrozenVerdict.observe(uniformBlank: false, displayIdleSeconds: 0.05,
                                             injected: true).evidence, [.injected])
    }

    /// しきい値の境界(ちょうどは「生きている」側)
    func testCountsAsFrozenBoundary() {
        let t = FrozenVerdict.displayIdleFrozenThreshold
        XCTAssertFalse(FrozenVerdict.countsAsFrozen(uniformBlank: true, displayIdleSeconds: t))
        XCTAssertTrue(FrozenVerdict.countsAsFrozen(uniformBlank: true, displayIdleSeconds: t + 0.01))
    }
}
