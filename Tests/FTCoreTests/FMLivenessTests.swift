// FMLiveness(FM の死活の機械グローバルな台帳)の検証。
//
// 見るのは規律そのもの: **3値(生/死/不明)を混ぜない** / **経路(text・vision)を独立に持つ** /
// **新しい観測が勝つ** / **同じ状態の書き直しを畳む**。どれも壊れると、この台帳が消したかった
// 「FM が死んでいるのに気づけない」か、その逆の「生きているのに死んだと言う」を作る。
//
// 書き込み先は env 越しにテストごとの一時ディレクトリへ逃がすが、FT_FM_LIVENESS_DIR 自体は
// プロセス全体の状態なので SharedResource.hostCaches で直列化する(FMUsageLedgerTests と同じ)。

import FTTestSupport
import XCTest
@testable import FTCore

final class FMLivenessTests: XCTestCase {
    private var dir: URL!
    private var savedEnv: String?

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMLivenessTests-\(UUID().uuidString)")
        savedEnv = ProcessInfo.processInfo.environment["FT_FM_LIVENESS_DIR"]
        setenv("FT_FM_LIVENESS_DIR", dir.path, 1)
        FMLiveness.resetWriteMemo()
    }

    override func tearDownWithError() throws {
        if let savedEnv { setenv("FT_FM_LIVENESS_DIR", savedEnv, 1) } else { unsetenv("FT_FM_LIVENESS_DIR") }
        FMLiveness.resetWriteMemo()
        try? FileManager.default.removeItem(at: dir)
    }

    /// 記録が無い = 不明。**死ではない**
    func testNoRecordIsUnknownNotDead() throws {
        try SharedResource.hostCaches.locked {
            let reading = FMLiveness.current()
            XCTAssertTrue(reading.isUnknown)
            XCTAssertFalse(reading.hasDead, "観測が無いことを死と読まない")
            XCTAssertNil(reading.deadSummary())
        }
    }

    /// 古い観測は不明へ倒す(生も死も)。**古い「生きている」を出し続けない**
    func testStaleVerdictBecomesUnknown() throws {
        try SharedResource.hostCaches.locked {
            let past = Date().addingTimeInterval(-FMLiveness.freshSeconds - 1)
            FMLiveness.record(path: .text, state: .alive, source: .probe, now: past)
            XCTAssertNil(FMLiveness.current().text, "freshSeconds を超えた観測は不明")
            XCTAssertNotNil(FMLiveness.read()?.text, "そのままの読みは古くても返す")
        }
    }

    /// 片方の経路を書いても、もう片方が消えない(独立に死ぬ・戻るため)
    func testPathsAreIndependent() throws {
        try SharedResource.hostCaches.locked {
            FMLiveness.record(path: .vision, state: .dead, source: .probe, error: "ANE 0x10006")
            FMLiveness.resetWriteMemo()
            FMLiveness.record(path: .text, state: .alive, source: .call)

            let reading = FMLiveness.current()
            XCTAssertEqual(reading.text?.state, .alive)
            XCTAssertEqual(reading.vision?.state, .dead, "text を書いても vision の死が消えない")
            XCTAssertEqual(reading.deadPaths, ["vision"])
            XCTAssertEqual(reading.deadSummary(), "vision: ANE 0x10006")
        }
    }

    /// 両方死んでいるときは両方名指しする(次の一手が違うため)。順序は text→vision で固定
    func testBothPathsDeadAreBothNamed() throws {
        try SharedResource.hostCaches.locked {
            FMLiveness.record(path: .vision, state: .dead, source: .probe, error: "vision boom")
            FMLiveness.resetWriteMemo()
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "text boom")

            let reading = FMLiveness.current()
            XCTAssertEqual(reading.deadPaths, ["text", "vision"])
            XCTAssertEqual(reading.deadSummary(), "text: text boom / vision: vision boom")
            XCTAssertEqual(reading.deadSummary(limit: 6), "text: ", "limit は載せ先ごとの上限")
        }
    }

    /// 生に戻ったらエラーは残さない(直っても前の理由が出続けるのを防ぐ)
    func testRecoveryClearsTheError() throws {
        try SharedResource.hostCaches.locked {
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "boom")
            FMLiveness.resetWriteMemo()
            FMLiveness.record(path: .text, state: .alive, source: .probe)
            XCTAssertNil(FMLiveness.current().text?.error)
        }
    }

    /// 古い観測は新しい観測を上書きしない(書き手は複数プロセス)
    func testOlderObservationDoesNotOverwriteNewer() throws {
        try SharedResource.hostCaches.locked {
            let now = Date()
            FMLiveness.record(path: .text, state: .alive, source: .probe, now: now)
            FMLiveness.resetWriteMemo()
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "stale",
                              now: now.addingTimeInterval(-30))
            XCTAssertEqual(FMLiveness.read()?.text?.state, .alive, "古い観測は負ける")
        }
    }

    /// 同じ状態の書き直しは畳むが、**状態が変わった回は即書く**(死んだ瞬間を遅らせない)
    func testStateChangeIsWrittenImmediatelyWhileRepeatsAreCoalesced() throws {
        try SharedResource.hostCaches.locked {
            let now = Date()
            FMLiveness.record(path: .text, state: .alive, source: .call, ms: 900, now: now)
            // 同じ状態・1秒後 → 書かない(前回の ms が残る)
            FMLiveness.record(path: .text, state: .alive, source: .call, ms: 1, now: now.addingTimeInterval(1))
            XCTAssertEqual(FMLiveness.read()?.text?.ms, 900, "同じ状態の連投は畳む")
            // 状態が変わった → coalesce の窓の中でも即書く
            FMLiveness.record(path: .text, state: .dead, source: .call, error: "boom",
                              now: now.addingTimeInterval(2))
            XCTAssertEqual(FMLiveness.read()?.text?.state, .dead, "状態が変わったら畳まない")
        }
    }

    /// FMHealth の実呼び出し経由: **単発の失敗では死と言わない**(機械全体へ配る値のため)
    func testSingleFailureDoesNotDeclareDeath() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            XCTAssertNil(FMLiveness.read()?.vision, "1回の失敗では書かない")

            for _ in 1..<FMBreaker.threshold {
                FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            }
            XCTAssertEqual(FMLiveness.read()?.vision?.state, .dead, "閾値に達したら死")
            XCTAssertEqual(FMLiveness.read()?.vision?.source, .call)
            XCTAssertNil(FMLiveness.read()?.text, "vision の失敗で text を死と書かない")
        }
    }

    /// 成功は連続失敗の数え直しをする(間に成功が挟まれば、失敗の総数が閾値を超えても死と言わない)。
    /// **最後を失敗で終える** —— 成功で終えると数え直しの有無に関わらず最後の書き込みが alive に
    /// なり、数え直しを消す変異が素通りする(2026-09-03 の変異チェックで実際に生き残った)
    func testSuccessResetsTheFailureStreak() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            for _ in 0..<(FMBreaker.threshold - 1) {
                FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
                FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: true)
            }
            FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            XCTAssertEqual(FMLiveness.read()?.vision?.state, .alive,
                           "失敗の総数は閾値に達しているが、連続はしていない")
        }
    }

    /// 着地しなかった書き込みが、その直後の正当な書き込みを畳んで消さない。
    /// 控えを「書こうとした回」で進めると、ディスクに1度も着地しない状態が続く
    func testARejectedWriteDoesNotSwallowTheNextOne() throws {
        try SharedResource.hostCaches.locked {
            let now = Date()
            FMLiveness.record(path: .text, state: .alive, source: .probe, now: now)
            // 自分より新しい観測が既に居るので、この書き込みは着地しない
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "stale",
                              now: now.addingTimeInterval(-1))
            // coalesce の窓(5秒)の内側に来る正当な観測。**これは着地しなければならない**
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "real",
                              now: now.addingTimeInterval(1))
            XCTAssertEqual(FMLiveness.read()?.text?.error, "real")
        }
    }

    /// host-metrics の1行に死活が載る。**生・不明のときは null**(0件と混ぜない)
    func testHostMetricsLineCarriesLiveness() throws {
        let dead = FMLiveness.Reading(
            text: nil,
            vision: FMLiveness.Verdict(state: .dead, checkedAt: 1_700_000_000, source: .probe,
                                       error: "ANE 0x10006"))
        let line = HostMetricsSample(
            ts: 1_700_000_001, cpu: 0.1, gpu: 0.2, memUsedBytes: 1, memTotalBytes: 2,
            fmCalls: 0, fmFailures: 0, fmTotalMs: 0, fmLiveness: dead).encodedLine()
        let json = try XCTUnwrap(line)
        XCTAssertTrue(json.contains("\"fmVisionState\":\"dead\""), json)
        XCTAssertTrue(json.contains("\"fmTextState\":null"), "観測の無い経路は null(不明)。\(json)")
        XCTAssertTrue(json.contains("\"fmDeadReason\":\"vision: ANE 0x10006\""), json)
        XCTAssertTrue(json.contains("\"fmCheckedAt\":1700000000"), json)

        let quiet = HostMetricsSample(
            ts: 1, cpu: nil, gpu: nil, memUsedBytes: nil, memTotalBytes: nil,
            fmCalls: 0, fmFailures: 0, fmTotalMs: 0).encodedLine()
        XCTAssertTrue(try XCTUnwrap(quiet).contains("\"fmDeadReason\":null"),
                      "死活を渡さない呼び出し元は不明のまま(欄は必ず出す)")
    }

    /// 1Hz で流す行はエラー全文を載せない(切り詰めの上限が効いている)
    func testHostMetricsDeadReasonIsTruncated() throws {
        let long = String(repeating: "x", count: 900)
        let sample = HostMetricsSample(
            ts: 1, cpu: nil, gpu: nil, memUsedBytes: nil, memTotalBytes: nil,
            fmCalls: nil, fmFailures: nil, fmTotalMs: nil,
            fmLiveness: FMLiveness.Reading(
                text: FMLiveness.Verdict(state: .dead, checkedAt: 1, source: .probe, error: long),
                vision: nil))
        XCTAssertEqual(sample.fmDeadReason?.count, HostMetricsSample.deadReasonLimit)
    }
}
