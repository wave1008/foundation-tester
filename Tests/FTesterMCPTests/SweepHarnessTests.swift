// 実アプリのスナップショットへ検知を全数で当てる回帰ゲート。
//
// **自前の 4 SUT は遮蔽・積み重なり・中身外しの形を代表しない** —— 2026-08-07 の3ラウンドで、
// 誤検知も真陽性も実アプリでだけ出た(4 SUT では1件も出ない)。だからコーパスを
// Tests/Fixtures/RealAppSnapshots/ に固定して、件数を基準値と突き合わせる。
//
// **「増えていないこと」を見るのが目的**。新しい検知を足したときに、それが雑音になっていないかは
// 自分では分からない(2026-08-07 に4種足した)。基準値を上げるのは、増えた分を1件ずつ見て
// 真陽性だと確かめてからにすること —— 黙って上げると、この砦は現状の追認装置になる。
//
// 別のコーパスへ当てたいときは FT_SWEEP_DIR でディレクトリを差し替える(件数の照合はしない)。

import XCTest
import FTCore
@testable import ftester_mcp

final class SweepHarnessTests: XCTestCase {

    /// 1画面ぶんの検知件数
    struct Counts: Equatable, CustomStringConvertible {
        var ghost = 0, overlay = 0, stacked = 0, misses = 0, disabled = 0, warnedTappable = 0
        var description: String {
            "ghost=\(ghost) overlay=\(overlay) stacked=\(stacked) misses=\(misses)"
                + " disabled=\(disabled) warnedTappable=\(warnedTappable)"
        }
    }

    /// 2026-08-07 時点の実測値。**すべて中身を確認済み**:
    /// - `overlay` は全画面シート・app bar・下部フッタが実際に覆っている真陽性
    /// - `misses` は中心が中身のどこにも乗らない容器(`#layers_fab_button` 等)
    /// - `disabled` は E2E-CMP の契約上「押しても何も起きない」2ボタンだけ
    /// - `ghost` と `stacked` は**全画面で 0**(2026-08-07 に誤検知を潰した結果)
    static let baselines: [String: Counts] = [
        "and-home": Counts(ghost: 0, overlay: 2, stacked: 0, misses: 2, disabled: 0,
                           warnedTappable: 0),
        "and-overflow": Counts(),
        "and-place": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 1, disabled: 0,
                            warnedTappable: 0),
        "and-place_expanded": Counts(ghost: 0, overlay: 11, stacked: 0, misses: 0, disabled: 0,
                                     warnedTappable: 3),
        "and-results": Counts(ghost: 0, overlay: 18, stacked: 0, misses: 2, disabled: 0,
                              warnedTappable: 2),
        "ios-home": Counts(ghost: 0, overlay: 1, stacked: 0, misses: 0, disabled: 0,
                           warnedTappable: 0),
        "ios-place": Counts(ghost: 0, overlay: 3, stacked: 0, misses: 2, disabled: 0,
                            warnedTappable: 0),
        "ios-profile": Counts(),
        "sut-cmp_controls": Counts(ghost: 0, overlay: 0, stacked: 0, misses: 0, disabled: 2,
                                   warnedTappable: 2),
        "sut-cmp_home": Counts(),
    ]

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/FTesterMCPTests/このファイル
            .deletingLastPathComponent()          // Tests/FTesterMCPTests
            .deletingLastPathComponent()          // Tests
            .appendingPathComponent("Fixtures/RealAppSnapshots")
    }

    static func counts(_ snap: SnapshotResponse) -> Counts {
        let els = snap.elements
        let stacked = RefGuard.stackedRefs(els)
        var c = Counts()
        for e in els {
            let ghost = RefGuard.isUntappableGhost(e, in: els, screen: snap.screen)
            let overlay = RefGuard.overlayCovering(e, in: els, screen: snap.screen) != nil
            let misses = RefGuard.missesItsOwnContent(e, in: els, screen: snap.screen) != nil
            if ghost { c.ghost += 1 }
            if overlay { c.overlay += 1 }
            if stacked.contains(e.ref) { c.stacked += 1 }
            if misses { c.misses += 1 }
            // **production の関数を通す**: ここで `!e.enabled` を自前で見ると、
            // `RefGuard.disabledWarning` を壊してもこのゲートが落ちない(2026-08-07 の
            // 変異テストで実際に素通しした)。検知の回帰を見る砦なので必ず本番経路で数える
            let disabled = !RefGuard.disabledWarning(e).isEmpty
            if disabled { c.disabled += 1 }
            if RefGuard.interactiveTypes.contains(e.type),
               ghost || overlay || misses || stacked.contains(e.ref) || disabled {
                c.warnedTappable += 1
            }
        }
        return c
    }

    private func load(_ url: URL) throws -> SnapshotResponse {
        try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    /// 固定コーパスに対して件数が基準値どおりであること
    func testDetectionCountsMatchTheBaseline() throws {
        let dir = Self.fixtureDirectory
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(files.count, Self.baselines.count,
                       "フィクスチャと基準値の数が合っていない: \(files)")
        for file in files {
            let name = String(file.dropLast(".json".count))
            guard let expected = Self.baselines[name] else {
                XCTFail("基準値が無いフィクスチャ: \(name)"); continue
            }
            let actual = Self.counts(try load(dir.appendingPathComponent(file)))
            XCTAssertEqual(actual, expected,
                           "\(name) の検知件数が変わった。**増えた分を1件ずつ見て真陽性だと"
                           + "確かめてから**基準値を更新すること(\(actual) vs \(expected))")
        }
    }

    /// **雑音になっていないこと**: タップ対象のうち警告が付く割合の上限。
    /// 2026-08-07 の実測は実アプリで 0〜10%、自前 SUT の controls 画面だけ 18%
    /// (契約上の無効ボタン2つ = 真陽性)
    func testWarningDensityStaysLow() throws {
        let dir = Self.fixtureDirectory
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter({ $0.hasSuffix(".json") }).sorted() {
            let snap = try load(dir.appendingPathComponent(file))
            let tappable = snap.elements.filter { RefGuard.interactiveTypes.contains($0.type) }
            guard !tappable.isEmpty else { continue }
            let warned = Self.counts(snap).warnedTappable
            let percent = warned * 100 / tappable.count
            XCTAssertLessThanOrEqual(percent, 20,
                                     "\(file): タップ対象の \(percent)% に警告が付いている"
                                     + " —— 検知ではなく雑音になっていないか見ること")
        }
    }

    /// 基準値の採り直し用(FT_SWEEP_BASELINE=1 のときだけ動く)。**貼り付け用の1行と、
    /// 何が発火したかの明細を両方出す** —— 基準値を上げる前に1件ずつ真陽性を確かめるため
    func testPrintBaselines() throws {
        guard ProcessInfo.processInfo.environment["FT_SWEEP_BASELINE"] == "1" else { return }
        let dir = Self.fixtureDirectory
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter({ $0.hasSuffix(".json") }).sorted() {
            let snap = try load(dir.appendingPathComponent(file))
            let c = Self.counts(snap)
            let name = String(file.dropLast(".json".count))
            print("BASELINE \"\(name)\": Counts(ghost: \(c.ghost), overlay: \(c.overlay),"
                + " stacked: \(c.stacked), misses: \(c.misses), disabled: \(c.disabled),"
                + " warnedTappable: \(c.warnedTappable)),")
            let els = snap.elements
            for e in els {
                let who = RefGuard.describe(e)
                if let hit = RefGuard.overlayCovering(e, in: els, screen: snap.screen) {
                    print("   DETAIL \(name) overlay  \(who) ← \(RefGuard.describe(hit))")
                }
                if let inner = RefGuard.missesItsOwnContent(e, in: els, screen: snap.screen) {
                    print("   DETAIL \(name) misses   \(who) → \(RefGuard.describe(inner))")
                }
                if RefGuard.isUntappableGhost(e, in: els, screen: snap.screen) {
                    print("   DETAIL \(name) ghost    \(who)")
                }
            }
        }
    }

    /// 別コーパスを当てるときの口(件数の照合はしない。FT_SWEEP_DIR を渡したときだけ動く)

    func testSweepExternalCorpus() throws {
        guard let dir = ProcessInfo.processInfo.environment["FT_SWEEP_DIR"] else { return }
        for file in try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter({ $0.hasSuffix(".json") }).sorted() {
            let snap = try load(URL(fileURLWithPath: dir).appendingPathComponent(file))
            print("SWEEP \(file) elements=\(snap.elements.count) \(Self.counts(snap))")
        }
    }
}
