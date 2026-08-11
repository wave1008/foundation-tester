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

    /// 拍動の停止は単独では確定させない(表示の停止とアプリのハングを分けられない)
    func testNoPresentAloneIsSuspectedOnly() {
        let verdict = FrozenVerdict([.noPresent])
        XCTAssertFalse(verdict.isFrozen)
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

    /// **拍動が生きていても凍結でありうる**(2026-08-11 の実験で反証)。本物の wedge を
    /// 故意に起こしたところ、画面が完全に固まっていても拍動は 0.001〜0.016s で回っていた。
    /// 一度これを否定材料に使ったが、それでは本物を1件も検出できない
    func testLiveHeartbeatDoesNotDenyAFreeze() {
        let verdict = FrozenVerdict.observe(uniformBlank: true, displayIdleSeconds: 0.005)
        XCTAssertTrue(verdict.isFrozen, "拍動を否定材料にすると本物の wedge を取り逃がす")
        XCTAssertEqual(verdict.evidence, [.uniformBlank])
    }

    /// 一様 + 拍動も停止なら根拠が2つ揃う
    func testUniformFrameWithStalledDisplayIsFrozen() {
        let verdict = FrozenVerdict.observe(uniformBlank: true, displayIdleSeconds: 30)
        XCTAssertTrue(verdict.isFrozen)
        XCTAssertEqual(verdict.evidence, [.uniformBlank, .noPresent])
    }

    /// 申告が無くても一様なら凍結(拍動はあってもなくても判定を変えない)
    func testUniformFrameWithoutHeartbeatStaysFrozen() {
        XCTAssertTrue(FrozenVerdict.observe(uniformBlank: true, displayIdleSeconds: nil).isFrozen)
    }

    /// 拍動が止まっているだけ(画面は一様でない)は疑いどまり
    func testStalledDisplayAloneIsSuspected() {
        let verdict = FrozenVerdict.observe(uniformBlank: false, displayIdleSeconds: 30)
        XCTAssertFalse(verdict.isFrozen)
        XCTAssertTrue(verdict.isSuspected)
    }

    /// **観測窓が偽陽性と本物を分ける**(拍動ではない)。窓は約10秒に延ばしてある
    func testObservationWindowIsLongEnoughToOutlastFirstPaint() {
        let spanMs = BlankWorkerTriage.intervalMs * (BlankWorkerTriage.samples - 1)
        XCTAssertGreaterThanOrEqual(spanMs, 8_000,
                                    "窓が短いとアプリの初回描画待ちを凍結と誤断する(実測 13/13)")
    }

    /// 健全(一様でない)
    func testHealthyObservation() {
        XCTAssertEqual(FrozenVerdict.observe(uniformBlank: false, displayIdleSeconds: 0.05), .healthy)
    }

    /// 注入は観測に優先する(陽性対照が他の根拠に埋もれない)
    func testInjectionWins() {
        XCTAssertEqual(FrozenVerdict.observe(uniformBlank: false, displayIdleSeconds: 0.05,
                                             injected: true).evidence, [.injected])
    }

    /// 一様でなければ凍結ではない(拍動の値に関わらず)
    func testNonUniformIsNotFrozenRegardlessOfHeartbeat() {
        XCTAssertFalse(FrozenVerdict.countsAsFrozen(uniformBlank: false, displayIdleSeconds: 0.01))
        XCTAssertFalse(FrozenVerdict.countsAsFrozen(uniformBlank: false, displayIdleSeconds: 30))
    }
}
