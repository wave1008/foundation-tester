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
        let verdict = FrozenVerdict([.uniformBlank, .injected])
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

    /// **観測窓が偽陽性と本物を分ける**(拍動ではない)。窓は約10秒に延ばしてある
    func testObservationWindowIsLongEnoughToOutlastFirstPaint() {
        let spanMs = BlankWorkerTriage.intervalMs * (BlankWorkerTriage.samples - 1)
        XCTAssertGreaterThanOrEqual(spanMs, 8_000,
                                    "窓が短いとアプリの初回描画待ちを凍結と誤断する(実測 13/13)")
    }

    /// 健全(一様でない)
    func testHealthyObservation() {
        XCTAssertEqual(FrozenVerdict.observe(uniformBlank: false), .healthy)
    }

    /// 一様なら凍結
    func testUniformObservationIsFrozen() {
        XCTAssertEqual(FrozenVerdict.observe(uniformBlank: true).evidence, [.uniformBlank])
    }

    /// 注入は観測に優先する(陽性対照が他の根拠に埋もれない)
    func testInjectionWins() {
        XCTAssertEqual(FrozenVerdict.observe(uniformBlank: false, injected: true).evidence, [.injected])
    }

    /// 一様でなければ凍結ではない
    func testNonUniformIsNotFrozen() {
        XCTAssertFalse(FrozenVerdict.countsAsFrozen(uniformBlank: false))
    }
}

/// 共有ストアの消し込み。**回復したら公表を消す**が守られているかを固定する。
/// 2026-08-11 の実害: Android の回復は sleep/wake と guest restart の2段だが、
/// 消し込みが sleep/wake の分岐にしか無く、guest restart で戻った機は run の間ずっと
/// ❄️ のままだった(モニターは公表を無条件に取り込む)。
final class DeviceFrozenStoreClearTests: XCTestCase {

    private func makeStateDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testPublishThenClearRemovesTheVerdict() {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        DeviceFrozenStore.publish(stateDir: dir, key: "emulator-5554",
                                  verdict: FrozenVerdict([.uniformBlank]))
        XCTAssertEqual(DeviceFrozenStore.current(stateDir: dir, key: "emulator-5554"),
                       FrozenVerdict([.uniformBlank]))
        DeviceFrozenStore.clear(stateDir: dir, key: "emulator-5554")
        XCTAssertNil(DeviceFrozenStore.current(stateDir: dir, key: "emulator-5554"),
                     "回復したのに公表が残ると、描画している機に ❄️ が出続ける")
    }

    /// **死んだプロセスの公表は採らない**(run が落ちても ❄️ が残り続けない)
    func testVerdictFromADeadProcessIsIgnored() {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        DeviceFrozenStore.publish(stateDir: dir, key: "udid-a",
                                  verdict: FrozenVerdict([.uniformBlank]), pid: 999_999)
        XCTAssertNil(DeviceFrozenStore.current(stateDir: dir, key: "udid-a"))
    }

    /// 消し込みは対象キーだけに効く(他機の公表を巻き添えにしない)
    func testClearOnlyAffectsTheGivenKey() {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        DeviceFrozenStore.publish(stateDir: dir, key: "a", verdict: FrozenVerdict([.uniformBlank]))
        DeviceFrozenStore.publish(stateDir: dir, key: "b", verdict: FrozenVerdict([.uniformBlank]))
        DeviceFrozenStore.clear(stateDir: dir, key: "a")
        XCTAssertNil(DeviceFrozenStore.current(stateDir: dir, key: "a"))
        XCTAssertNotNil(DeviceFrozenStore.current(stateDir: dir, key: "b"))
    }

    /// 撤去済みの根拠(`noPresent`。rawValue はケース名そのままなので旧ファイルは "noPresent")を
    /// 含む旧版のファイルは decode に失敗し、**健全(nil)側へ倒れる**こと(誤って凍結扱いにしない)
    func testLegacyNoPresentEvidenceDecodesAsHealthy() throws {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "legacy-device"
        let legacy = """
        {"pid":\(ProcessInfo.processInfo.processIdentifier),"at":\(Date().timeIntervalSince1970),\
        "verdict":{"evidence":["noPresent"]}}
        """
        try legacy.data(using: .utf8)!.write(to: DeviceFrozenStore.entryURL(stateDir: dir, key: key))
        XCTAssertNil(DeviceFrozenStore.current(stateDir: dir, key: key),
                     "撤去済み根拠を含む旧JSONは decode 失敗→healthy に倒れること")
    }
}

