import XCTest
@testable import FTDSL
import FTCore

/// `LocatorFingerprintCache.flush` は並列のシナリオ実行プロセス間で同じファイルを取り合う
/// (レーン並列で同じシナリオ・同じ OS を複数プロファイルが同時に回すと、別プロセスの
/// インスタンスが同じ鍵空間を触りうる)。実プロセス並列は再現しない ── flush を呼ぶ順序
/// (誰が先に読み・後から書くか)だけで衝突を再現できる。
final class LocatorFingerprintConcurrentFlushTests: XCTestCase {

    private func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-fingerprint-concurrent-\(name)-\(UUID().uuidString).json")
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

    /// **①**: 2つの並列レーンを模した2インスタンスが別々の鍵を記録し、順に flush する。
    /// 先に flush した側の鍵が、後から flush した側の書き戻しで消えてはいけない。
    /// 「flush が自分の entries 全体を無条件で書く」実装だと、B の flush が A の書き込みを
    /// 見ずに上書きし keyA が消える
    func testConcurrentInstancesBothPersistTheirOwnKeys() {
        let url = tempURL("both-survive")
        let scenarioID = "Fingerprint.Concurrent.Basic"
        let keyA = "\(scenarioID)|ios|s.swift:10|#btn_a"
        let keyB = "\(scenarioID)|ios|s.swift:11|#btn_b"

        let cacheA = LocatorFingerprintCache(url: url)
        let cacheB = LocatorFingerprintCache(url: url)

        cacheA.record(keyA, fingerprint: fp("A"))
        cacheB.record(keyB, fingerprint: fp("B"))

        cacheA.flush(scenarioID: scenarioID, platform: "ios", scenarioPassed: false)
        cacheB.flush(scenarioID: scenarioID, platform: "ios", scenarioPassed: false)

        let entries = readEntries(url)
        XCTAssertEqual(entries.count, 2, "後から flush した側が先客の鍵を消してはいけない")
        XCTAssertEqual(entries[keyA]?.label, "A")
        XCTAssertEqual(entries[keyB]?.label, "B")
    }

    /// **②**: A が消した鍵を、その鍵が在った時点のディスクを読んでいた(が触れていない)B の
    /// 書き戻しで生き返らせてはいけない。「flush が自分がロードした古い local entries を
    /// そのまま書く」実装だと、B の flush が A の削除を上書きして keyRemoved が復活する
    func testFlushDoesNotResurrectAKeyDeletedByAnotherInstance() {
        let url = tempURL("no-resurrect")
        let scenarioID = "Fingerprint.Concurrent.Resurrect"
        let keyRemoved = "\(scenarioID)|ios|s.swift:10|#btn_removed"
        let keyOther = "\(scenarioID)|ios|s.swift:11|#btn_other"
        let typeOnly = LocatorFingerprint(type: "button", label: nil, placeholder: nil)

        do {
            let seed = LocatorFingerprintCache(url: url)
            seed.record(keyRemoved, fingerprint: fp("Removed"))
            seed.flush(scenarioID: scenarioID, platform: "ios", scenarioPassed: false)
        }
        XCTAssertEqual(readEntries(url).count, 1, "前提が崩れている")

        // B は keyRemoved がまだ在る時点のディスクを読み込む(古い写しを持つ)
        let cacheB = LocatorFingerprintCache(url: url)
        XCTAssertEqual(cacheB.lookup(keyRemoved)?.label, "Removed", "前提が崩れている")

        // A は keyRemoved を「名指しでなくなった」と判定して消し、先に flush する
        let cacheA = LocatorFingerprintCache(url: url)
        cacheA.record(keyRemoved, fingerprint: typeOnly)
        cacheA.flush(scenarioID: scenarioID, platform: "ios", scenarioPassed: false)
        XCTAssertTrue(readEntries(url).isEmpty, "前提が崩れている: A の削除が反映されていない")

        // B は keyRemoved に触れず、無関係の keyOther だけ記録して flush する
        cacheB.record(keyOther, fingerprint: fp("Other"))
        cacheB.flush(scenarioID: scenarioID, platform: "ios", scenarioPassed: false)

        let entries = readEntries(url)
        XCTAssertNil(entries[keyRemoved], "A が消した鍵が B の書き戻しで生き返ってはいけない")
        XCTAssertEqual(entries[keyOther]?.label, "Other")
        XCTAssertEqual(entries.count, 1)
    }

    /// **③**: 刈り取り(`scenarioPassed` の失効)は併合後のディスク内容に対して行われ、
    /// 自分のシナリオ+OS の接頭辞に入らない鍵を巻き込まない。A が読んだ時点ではまだ
    /// 存在しなかった B の鍵(A の flush より前に B が並行して足した)も、A の刈り取りに
    /// 巻き込まれてはいけない ── 刈り取りが「自分がロードした古いディスク像」ではなく
    /// 「flush 時点で読み直した最新の併合結果」に対して働くことの確認
    func testPruneAfterMergeDoesNotTouchConcurrentlyAddedOtherScenarioKeys() {
        let url = tempURL("prune-merge-isolation")
        let scenarioA = "Fingerprint.Concurrent.PruneA"
        let scenarioB = "Fingerprint.Concurrent.PruneB"
        let keyA1 = "\(scenarioA)|ios|s.swift:10|#btn_a1"
        let keyA2 = "\(scenarioA)|ios|s.swift:11|#btn_a2"
        let keyB1 = "\(scenarioB)|ios|s.swift:20|#btn_b1"
        let keyB2 = "\(scenarioB)|ios|s.swift:21|#btn_b2"

        do {
            let seed = LocatorFingerprintCache(url: url)
            seed.record(keyA1, fingerprint: fp("A1"))
            seed.record(keyA2, fingerprint: fp("A2"))
            seed.record(keyB1, fingerprint: fp("B1"))
            seed.flush(scenarioID: "seed", platform: "ios", scenarioPassed: false)
        }
        XCTAssertEqual(readEntries(url).count, 3, "前提が崩れている")

        // 2つの並列レーンが同じ(まだ keyB2 の無い)ディスク状態を読み込む
        let cacheA = LocatorFingerprintCache(url: url)
        let cacheB = LocatorFingerprintCache(url: url)

        // シナリオ B のレーン: keyB1 に触れ、keyB2 を新規に記録して先に flush(通った)
        _ = cacheB.lookup(keyB1)
        cacheB.record(keyB2, fingerprint: fp("B2"))
        cacheB.flush(scenarioID: scenarioB, platform: "ios", scenarioPassed: true)

        // シナリオ A のレーン: keyA2 の行が消えたと想定し keyA1 だけ触れて通った run として flush。
        // A のローカルの写しは keyB2 を知らない(A の init 後に B が足した)
        cacheA.record(keyA1, fingerprint: fp("A1"))
        cacheA.flush(scenarioID: scenarioA, platform: "ios", scenarioPassed: true)

        let entries = readEntries(url)
        XCTAssertEqual(entries[keyA1]?.label, "A1", "触れた自分の鍵は残らなければいけない")
        XCTAssertNil(entries[keyA2], "触れなかった自分の鍵は刈られなければいけない")
        XCTAssertEqual(entries[keyB1]?.label, "B1", "他シナリオの鍵を刈ってはいけない")
        XCTAssertEqual(entries[keyB2]?.label, "B2",
                       "自分が読んだ後に別レーンが足した他シナリオの鍵を、刈り取りが消してはいけない")
        XCTAssertEqual(entries.count, 3)
    }
}
