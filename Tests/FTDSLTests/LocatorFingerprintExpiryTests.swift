import XCTest
@testable import FTDSL
import FTCore

/// `LocatorFingerprintCache.flush(scenarioID:scenarioPassed:)` の失効規則(古い鍵の刈り取り)。
/// 鍵の実文字列(`HealCache.key` の形)は生成せず手で組む —— ここで検証したいのは
/// キャッシュ層の刈り取り条件そのもので、鍵の生成規則は既存の他テストが担う。
/// FTDriveCore 経由の実配線確認(record() → flush() の一気通貫)は
/// LocatorFingerprintRecordingTests.testPassedScenarioPrunesUntouchedKeyThroughFTDriveCore を参照。
final class LocatorFingerprintExpiryTests: XCTestCase {

    private func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-fingerprint-expiry-\(name)-\(UUID().uuidString).json")
    }

    private func readEntries(_ url: URL) -> [String: LocatorFingerprint] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: LocatorFingerprint].self, from: data)
        else { return [:] }
        return decoded
    }

    private func fp(_ label: String) -> LocatorFingerprint {
        LocatorFingerprint(type: "button", label: label, placeholder: nil)
    }

    /// **本題**: 通った run で、その run が触れなかった同一シナリオの古い鍵は消える。
    /// 触れた鍵は残る。「常に刈る」変異(条件を無視して常に untouched を消す)は
    /// このテストだけでは検出できない(それも消えるのが正しい)ので、
    /// 「決して刈らない」変異(count が 2 のまま)を落とす側
    func testPassedRunPrunesUntouchedKeysButKeepsTouched() {
        let url = tempURL("prune-basic")
        let scenarioID = "Fingerprint.Prune.Basic"
        let keyA = "\(scenarioID)|s.swift:10|#btn_a"
        let keyB = "\(scenarioID)|s.swift:11|#btn_b"

        // run1: 両方記録して flush(通った)
        do {
            let cache = LocatorFingerprintCache(url: url)
            cache.record(keyA, fingerprint: fp("Label A"))
            cache.record(keyB, fingerprint: fp("Label B"))
            cache.flush(scenarioID: scenarioID, scenarioPassed: true)
        }
        XCTAssertEqual(readEntries(url).count, 2, "前提が崩れている: run1 で2件記録できていない")

        // run2: #btn_b の行が消えたと想定し keyA だけ触れる。通った run なので keyB は刈られる
        do {
            let cache = LocatorFingerprintCache(url: url)
            cache.record(keyA, fingerprint: fp("Label A"))
            cache.flush(scenarioID: scenarioID, scenarioPassed: true)
        }
        let entries = readEntries(url)
        XCTAssertEqual(entries.count, 1,
                       "触れなかった keyB が刈られていない、または触れた keyA まで消えている")
        XCTAssertNotNil(entries[keyA], "触れた鍵は残らなければいけない")
        XCTAssertNil(entries[keyB], "触れなかった鍵(古いソース配置の残骸)は消えなければいけない")
    }

    /// **最重要**: 他のシナリオの鍵には触れない。部分実行(`--scenario` 指定)で
    /// 無関係シナリオの指紋を巻き込んで消す退行を落とす
    func testDoesNotTouchOtherScenarioKeys() {
        let url = tempURL("prune-other-scenario")
        let scenarioA = "Fingerprint.Prune.Other.A"
        let scenarioB = "Fingerprint.Prune.Other.B"
        let keyA1 = "\(scenarioA)|s.swift:10|#btn_a"
        let keyA2 = "\(scenarioA)|s.swift:11|#btn_b"
        let keyB1 = "\(scenarioB)|s.swift:20|#btn_c"
        let keyB2 = "\(scenarioB)|s.swift:21|#btn_d"

        // シナリオ A の run(2件記録・通った)
        do {
            let cache = LocatorFingerprintCache(url: url)
            cache.record(keyA1, fingerprint: fp("A1"))
            cache.record(keyA2, fingerprint: fp("A2"))
            cache.flush(scenarioID: scenarioA, scenarioPassed: true)
        }
        // シナリオ B の run(2件記録・通った)。同じファイルへ相乗りする
        do {
            let cache = LocatorFingerprintCache(url: url)
            cache.record(keyB1, fingerprint: fp("B1"))
            cache.record(keyB2, fingerprint: fp("B2"))
            cache.flush(scenarioID: scenarioB, scenarioPassed: true)
        }
        XCTAssertEqual(readEntries(url).count, 4, "前提が崩れている: 2シナリオぶんの4件が揃っていない")

        // シナリオ B だけを部分実行(--scenario 指定を模す)。keyB2 に相当する行が消え、
        // keyB1 だけに触れて通す。シナリオ A のぶんには一切触れていない
        do {
            let cache = LocatorFingerprintCache(url: url)
            cache.record(keyB1, fingerprint: fp("B1"))
            cache.flush(scenarioID: scenarioB, scenarioPassed: true)
        }

        let entries = readEntries(url)
        XCTAssertNotNil(entries[keyA1], "無関係シナリオ A の鍵を消してはいけない")
        XCTAssertNotNil(entries[keyA2], "無関係シナリオ A の鍵を消してはいけない")
        XCTAssertNotNil(entries[keyB1], "触れた B の鍵は残らなければいけない")
        XCTAssertNil(entries[keyB2], "触れなかった B の鍵は刈られなければいけない")
        XCTAssertEqual(entries.count, 3)
    }

    /// 失敗した run では刈らない —— 中断は後続ステップに到達していないだけで、
    /// その先の鍵はまだ現役。「常に刈る」変異(`scenarioPassed` を無視する)が
    /// 入っていたら keyB が消えて落ちる
    func testFailedRunDoesNotPrune() {
        let url = tempURL("prune-failed")
        let scenarioID = "Fingerprint.Prune.Failed"
        let keyA = "\(scenarioID)|s.swift:10|#btn_a"
        let keyB = "\(scenarioID)|s.swift:11|#btn_b"

        do {
            let cache = LocatorFingerprintCache(url: url)
            cache.record(keyA, fingerprint: fp("A"))
            cache.record(keyB, fingerprint: fp("B"))
            cache.flush(scenarioID: scenarioID, scenarioPassed: true)
        }
        XCTAssertEqual(readEntries(url).count, 2, "前提が崩れている")

        // run2: keyA だけ触れて失敗で中断(keyB のステップへは到達していない)
        do {
            let cache = LocatorFingerprintCache(url: url)
            cache.record(keyA, fingerprint: fp("A"))
            cache.flush(scenarioID: scenarioID, scenarioPassed: false)
        }

        let entries = readEntries(url)
        XCTAssertEqual(entries.count, 2, "失敗した run で刈ってはいけない(keyB はまだ現役)")
        XCTAssertNotNil(entries[keyA])
        XCTAssertNotNil(entries[keyB])
    }

    /// 条件2 のガード: このシナリオで1件も record() していない run(全ステップがキャッシュ/指紋/
    /// FM ヒールで解決した)は、通っていても刈らない。このガードを外すと「1件も触れていない」を
    /// 「全部古い」と誤読し、そのシナリオの鍵を全部消してしまう(現役の指紋を根こそぎ失う退化)。
    /// 「常に刈る」変異が入っていたら keyA・keyB が両方消えて落ちる
    func testZeroRecordedThisRunDoesNotPrune() {
        let url = tempURL("prune-zero-recorded")
        let scenarioID = "Fingerprint.Prune.ZeroRecorded"
        let keyA = "\(scenarioID)|s.swift:10|#btn_a"
        let keyB = "\(scenarioID)|s.swift:11|#btn_b"

        do {
            let cache = LocatorFingerprintCache(url: url)
            cache.record(keyA, fingerprint: fp("A"))
            cache.record(keyB, fingerprint: fp("B"))
            cache.flush(scenarioID: scenarioID, scenarioPassed: true)
        }
        XCTAssertEqual(readEntries(url).count, 2, "前提が崩れている")

        // run2: このシナリオの鍵を1件も record() しない(全ステップが指紋/ヒールで解決した想定)。
        // 通った run なので scenarioPassed は true
        do {
            let cache = LocatorFingerprintCache(url: url)
            cache.flush(scenarioID: scenarioID, scenarioPassed: true)
        }

        let entries = readEntries(url)
        XCTAssertEqual(entries.count, 2, "1件も記録していない run で刈ってはいけない")
        XCTAssertNotNil(entries[keyA])
        XCTAssertNotNil(entries[keyB])
    }
}
