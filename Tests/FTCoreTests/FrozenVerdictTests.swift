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
}
