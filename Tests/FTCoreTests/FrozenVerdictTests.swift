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

    /// **拍動の停止は単独で確定させる**(2026-08-11 に格上げ)。画像は非決定的で、
    /// 「真っ白な画面」を凍結と誤認し(実測 13/13)、固着型は取り逃がす
    func testNoPresentAloneIsConclusive() {
        let verdict = FrozenVerdict([.noPresent])
        XCTAssertTrue(verdict.isFrozen)
        XCTAssertFalse(verdict.isSuspected)
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

    /// **固着型**(最後のフレームが残る = 非一様)も捕まえる。画像だけの判定では原理的に無理だった
    func testStalledDisplayWithNonUniformFrameIsFrozen() {
        let verdict = FrozenVerdict.observe(uniformBlank: false, displayIdleSeconds: 30)
        XCTAssertTrue(verdict.isFrozen, "固着型を取り逃がしている")
        XCTAssertEqual(verdict.evidence, [.noPresent])
    }

    /// **拍動があるなら画像は見ない**(判定が非決定的な材料に依存しない)
    func testHeartbeatWinsOverTheImage() {
        XCTAssertFalse(FrozenVerdict.countsAsFrozen(uniformBlank: true, displayIdleSeconds: 0.05))
        XCTAssertTrue(FrozenVerdict.countsAsFrozen(uniformBlank: false, displayIdleSeconds: 30))
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
