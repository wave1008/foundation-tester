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


/// テスト用: 壁時計の時刻をそのまま刻印の順序へ写す(同じ起動・ns)。`now:` で順序を表すテストに使う
fileprivate extension FMLiveness.Stamp {
    static func at(_ date: Date) -> FMLiveness.Stamp {
        FMLiveness.Stamp(boot: FMLiveness.Stamp.now().boot, mono: UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000))
    }
}

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
        // 死に変わった記録は裏で証拠を取りに行く(FMHistory)。待ち切ってから置き場を戻す
        FMHistory.waitForPendingEvidence()
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
            FMLiveness.record(path: .text, state: .alive, source: .probe, now: past, observed: .at(past))
            XCTAssertNil(FMLiveness.current().text, "freshSeconds を超えた観測は不明")
            XCTAssertNotNil(FMLiveness.read()?.text, "そのままの読みは古くても返す")
        }
    }

    /// 片方の経路を書いても、もう片方が消えない(独立に死ぬ・戻るため)
    func testPathsAreIndependent() throws {
        try SharedResource.hostCaches.locked {
            FMLiveness.record(path: .vision, state: .dead, source: .probe, error: "ANE 0x10006", observed: .now())
            FMLiveness.resetWriteMemo()
            FMLiveness.record(path: .text, state: .alive, source: .call, observed: .now())

            let reading = FMLiveness.current()
            XCTAssertEqual(reading.text?.state, .alive)
            XCTAssertEqual(reading.vision?.state, .dead, "text を書いても vision の死が消えない")
            XCTAssertEqual(reading.deadPaths, ["vision"])
            XCTAssertEqual(reading.deadSummary(), "vision: ANE 0x10006" + FMLiveness.Reading.deadSummaryNote)
        }
    }

    /// 両方死んでいるときは両方名指しする(次の一手が違うため)。順序は text→vision で固定
    func testBothPathsDeadAreBothNamed() throws {
        try SharedResource.hostCaches.locked {
            FMLiveness.record(path: .vision, state: .dead, source: .probe, error: "vision boom", observed: .now())
            FMLiveness.resetWriteMemo()
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "text boom", observed: .now())

            let reading = FMLiveness.current()
            XCTAssertEqual(reading.deadPaths, ["text", "vision"])
            XCTAssertEqual(reading.deadSummary(),
                           "text: text boom / vision: vision boom" + FMLiveness.Reading.deadSummaryNote)
            XCTAssertEqual(reading.deadSummary(limit: 6), "text: ", "limit は載せ先ごとの上限")
        }
    }

    /// 死んだ理由に「この Mac の再起動で戻ったことがある」の事実を足す。**必ず直るとは言わない**
    /// (2026-09-18 実測: ANE 異常からのカーネルパニック → 再起動直後は生き返った、の1回の観測)
    func testDeadSummaryAddsRebootNoteWithoutPromisingAFix() throws {
        try SharedResource.hostCaches.locked {
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "ModelManagerError(1001)", observed: .now())
            let summary = try XCTUnwrap(FMLiveness.current().deadSummary())
            XCTAssertTrue(summary.contains("rebooting this Mac"), summary)
            XCTAssertTrue(summary.contains("has cleared this state before"), summary)
            XCTAssertFalse(summary.lowercased().contains("will fix"), "必ず直るとは断定しない: \(summary)")
        }
    }

    /// 生に戻ったらエラーは残さない(直っても前の理由が出続けるのを防ぐ)
    func testRecoveryClearsTheError() throws {
        try SharedResource.hostCaches.locked {
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "boom", observed: .now())
            FMLiveness.resetWriteMemo()
            FMLiveness.record(path: .text, state: .alive, source: .probe, observed: .now())
            XCTAssertNil(FMLiveness.current().text?.error)
        }
    }

    /// 古い観測は新しい観測を上書きしない(書き手は複数プロセス)
    func testOlderObservationDoesNotOverwriteNewer() throws {
        try SharedResource.hostCaches.locked {
            let now = Date()
            FMLiveness.record(path: .text, state: .alive, source: .probe, now: now, observed: .at(now))
            FMLiveness.resetWriteMemo()
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "stale",
                              now: now.addingTimeInterval(-30), observed: .at(now.addingTimeInterval(-30)))
            XCTAssertEqual(FMLiveness.read()?.text?.state, .alive, "古い観測は負ける")
        }
    }

    /// 同じ状態の書き直しは畳むが、**状態が変わった回は即書く**(死んだ瞬間を遅らせない)
    func testStateChangeIsWrittenImmediatelyWhileRepeatsAreCoalesced() throws {
        try SharedResource.hostCaches.locked {
            let now = Date()
            FMLiveness.record(path: .text, state: .alive, source: .call, ms: 900, now: now, observed: .at(now))
            // 同じ状態・1秒後 → 書かない(前回の ms が残る)
            FMLiveness.record(path: .text, state: .alive, source: .call, ms: 1, now: now.addingTimeInterval(1), observed: .at(now.addingTimeInterval(1)))
            XCTAssertEqual(FMLiveness.read()?.text?.ms, 900, "同じ状態の連投は畳む")
            // 状態が変わった → coalesce の窓の中でも即書く
            // 自分で死と決める書き手(プローブ)。実呼び出しの失敗1回は閾値に届かないので死にならない
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "boom",
                              now: now.addingTimeInterval(2), observed: .at(now.addingTimeInterval(2)))
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

    /// **プローブの生も連続失敗を戻す**: run の実呼び出しの成功でしか戻らないと、プローブが生を見た後でも
    /// 前の失敗の数が残り、次の1回の失敗で閾値に届く。最後を失敗で終える(理由は上のテスト)
    func testProbeAliveResetsTheFailureStreak() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            for _ in 0..<(FMBreaker.threshold - 1) {
                FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            }
            FMLiveness.record(path: .vision, state: .alive, source: .probe, ms: 600, observed: .now())
            FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            XCTAssertNotEqual(FMLiveness.read()?.vision?.state, .dead, "プローブの生の後の1回の失敗で死と書いた")
        }
    }

    /// **生の観測より後の失敗は残す**(遅れて着いた古い成功が、その後の連続失敗を消さない)
    func testAnOlderAliveDoesNotResetANewerFailureStreak() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            let before = FMLiveness.Stamp.now()
            for _ in 0..<(FMBreaker.threshold - 1) {
                FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            }
            FMLiveness.record(path: .vision, state: .alive, source: .probe, ms: 600, observed: before)
            FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            XCTAssertEqual(FMLiveness.read()?.vision?.state, .dead, "古い生が新しい連続失敗を戻した")
        }
    }

    /// **成功より前の失敗は、遅れて着いても数えない**
    func testAFailureFromBeforeTheSuccessIsNotCountedEvenIfItArrivesLate() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            let boot = FMLiveness.Stamp.now().boot
            FMLiveness.resetFailureStreak(.vision, observedAt: FMLiveness.Stamp(boot: boot, mono: 3_000))
            XCTAssertEqual(FMLiveness.bumpFailureStreak(.vision, at: FMLiveness.Stamp(boot: boot, mono: 1_000)), 0)
            XCTAssertEqual(FMLiveness.bumpFailureStreak(.vision, at: FMLiveness.Stamp(boot: boot, mono: 4_000)), 1)
        }
    }

    /// 前回の起動の失敗は引き継がない(再起動を越えて数が残らない)
    func testFailuresFromAnotherBootAreDiscarded() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            for mono in [UInt64(5), 6, 7] {
                _ = FMLiveness.bumpFailureStreak(.vision, at: FMLiveness.Stamp(boot: "previous-boot", mono: mono))
            }
            XCTAssertEqual(FMLiveness.bumpFailureStreak(.vision, at: FMLiveness.Stamp(boot: "this-boot", mono: 1)), 1)
        }
    }

    /// 壁時計が戻っても、新しい生の観測は連続失敗を戻す(順序は壁時計ではなく刻印で決める)
    func testAWallClockStepBackDoesNotStopAResetFromANewerObservation() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            for _ in 0..<(FMBreaker.threshold - 1) {
                FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            }
            FMLiveness.record(path: .vision, state: .alive, source: .probe, ms: 600,
                              now: Date(timeIntervalSince1970: 1_000_000_000), observed: .now())
            FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            XCTAssertNotEqual(FMLiveness.read()?.vision?.state, .dead, "壁時計の古い生の観測が数を戻さなかった")
        }
    }

    /// **台帳の上書きの順序も刻印で決める**: 刻印の古い死は、壁時計が新しくても、刻印の新しい生を上書きしない
    /// (閾値の判定の後で止まっていた処理が、新しい成功の後に古い失敗で dead を書く型)
    func testALedgerWriteWithAnOlderStampDoesNotOverwriteANewerObservation() throws {
        try SharedResource.hostCaches.locked {
            let older = FMLiveness.Stamp.now()
            let newer = FMLiveness.Stamp(boot: older.boot, mono: older.mono + 1_000_000_000)
            let wall = Date()
            FMLiveness.record(path: .vision, state: .alive, source: .probe, now: wall, observed: newer)
            FMLiveness.record(path: .vision, state: .dead, source: .call, error: "late",
                              now: wall.addingTimeInterval(60), observed: older)
            XCTAssertEqual(FMLiveness.read()?.vision?.state, .alive, "刻印の古い死が新しい生を上書きした")
        }
    }

    /// 起動が識別できない刻印の観測は**共有しない**(台帳に書かず、識別できる起動の失敗の数にも混ざらない)。
    /// 混ぜると比較が単調時刻と壁時計で循環し、前回の起動の失敗も今回へ引き継ぐ
    func testUnknownBootObservationsAreNotShared() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            let unknown = FMLiveness.Stamp(boot: FMLiveness.Stamp.unknownBoot, mono: 5)
            for _ in 0..<3 { _ = FMLiveness.bumpFailureStreak(.vision, at: unknown) }
            FMLiveness.record(path: .vision, state: .dead, source: .probe, error: "x",
                              now: Date().addingTimeInterval(3600), observed: unknown)
            XCTAssertNil(FMLiveness.read()?.vision, "識別できない起動の観測を台帳に書いた")
            XCTAssertEqual(FMLiveness.bumpFailureStreak(.vision, at: .now()), 1, "識別できない起動の失敗が共有の数に混ざった")
        }
    }

    /// 起動の識別子は sysctl の値を先に、取れなければ親が渡した値を使う(子のサンドボックスで sysctl が読めなくても名乗れる)
    func testTheBootIDFallsBackToTheValueTheParentPassed() {
        let key = FMLiveness.Stamp.bootEnvironmentKey
        XCTAssertEqual(key, "FT_BOOT_SESSION_ID")
        XCTAssertEqual(FMLiveness.Stamp.resolveBootID(sysctl: "A", environment: [key: "B"]), "A")
        XCTAssertEqual(FMLiveness.Stamp.resolveBootID(sysctl: nil, environment: [key: "B"]), "B")
        XCTAssertNil(FMLiveness.Stamp.resolveBootID(sysctl: nil, environment: [key: ""]))
        XCTAssertNil(FMLiveness.Stamp.resolveBootID(sysctl: nil, environment: [:]))
    }

    /// シナリオのプロセスへ起動の識別子を渡す(親の環境の作り口)
    func testTheScenarioChildEnvironmentCarriesTheBootID() {
        let boot = FMLiveness.Stamp.bootID
        guard boot != FMLiveness.Stamp.unknownBoot else { return }
        XCTAssertEqual(ScenarioHost.childEnvironment(base: [:])[FMLiveness.Stamp.bootEnvironmentKey], boot)
    }

    /// 無条件の戻しは、プロセスの中の記録(識別できない起動)も消す
    func testAnUnconditionalResetClearsTheInProcessFailuresToo() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            let unknown = FMLiveness.Stamp(boot: FMLiveness.Stamp.unknownBoot, mono: 5)
            for _ in 0..<2 { _ = FMLiveness.bumpFailureStreak(.vision, at: unknown) }
            FMLiveness.resetFailureStreak(.vision)
            XCTAssertEqual(FMLiveness.bumpFailureStreak(.vision, at: unknown), 1)
        }
    }

    /// **遅れて着いた成功で実呼び出しの死の根拠が消えたら、台帳も生に戻す**(観測 失敗10・成功20・失敗30・失敗40、
    /// 着いた順 10 → 30 → 40 → 20。最新の生より後の失敗は [30, 40] = 閾値未満)
    func testALateSuccessThatBreaksTheStreakCorrectsACallDeath() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            let boot = FMLiveness.Stamp.now().boot
            func at(_ mono: UInt64) -> FMLiveness.Stamp { FMLiveness.Stamp(boot: boot, mono: mono) }
            for mono in [UInt64(10), 30, 40] {
                FMLiveness.recordCallFailure(path: .vision, error: "boom", ms: 1, observed: at(mono))
            }
            XCTAssertEqual(FMLiveness.read()?.vision?.state, .dead)
            FMLiveness.record(path: .vision, state: .alive, source: .call, ms: 1, observed: at(20))
            XCTAssertEqual(FMLiveness.read()?.vision?.state, .alive, "最新の生より後の失敗が閾値未満なのに死が残った")
        }
    }

    /// 全部の失敗より前の成功が遅れて着いても、死のまま(その成功の後に閾値ぶんの失敗がある)
    func testALateSuccessBeforeAllFailuresKeepsTheDeath() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            let boot = FMLiveness.Stamp.now().boot
            func at(_ mono: UInt64) -> FMLiveness.Stamp { FMLiveness.Stamp(boot: boot, mono: mono) }
            for mono in [UInt64(10), 30, 40] {
                FMLiveness.recordCallFailure(path: .vision, error: "boom", ms: 1, observed: at(mono))
            }
            FMLiveness.record(path: .vision, state: .alive, source: .call, ms: 1, observed: at(5))
            XCTAssertEqual(FMLiveness.read()?.vision?.state, .dead)
        }
    }

    /// 根拠の無い(前の版が書いた)記録は、壁時計で未来にあっても、新しい観測から導いた判定で置き換わる(移行)。
    /// 未来の記録は新しいとみなさない
    func testALegacyFutureRecordIsReplacedAndFutureRecordsAreNotFresh() throws {
        try SharedResource.hostCaches.locked {
            let future = Date().addingTimeInterval(3600)
            let legacy = FMLiveness.Record(vision: FMLiveness.Verdict(state: .dead, checkedAt: future.timeIntervalSince1970,
                                                                       source: .probe, error: "old"))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(legacy).write(to: dir.appendingPathComponent("fm-liveness.json"))
            XCTAssertFalse(try XCTUnwrap(legacy.vision).isFresh(), "1時間先の記録を新しいとみなした")
            FMLiveness.record(path: .vision, state: .alive, source: .probe, ms: 1, observed: .now())
            XCTAssertEqual(FMLiveness.read()?.vision?.state, .alive, "根拠の無い未来の記録から移行できなかった")
        }
    }

    /// 無条件の戻し(FMHealth.reset)は実呼び出しの失敗を消す
    func testAnUnconditionalResetClearsTheCallFailures() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            for _ in 0..<2 { _ = FMLiveness.bumpFailureStreak(.vision, at: .now()) }
            FMLiveness.resetFailureStreak(.vision)
            XCTAssertEqual(FMLiveness.bumpFailureStreak(.vision, at: .now()), 1)
        }
    }

    /// **導く判定は観測の着く順に依らない**: Codex レビューで挙がった順序の型(遅れて着く成功・失敗・別の書き手の死)を、
    /// 着く順のすべての並べ替えで足し、判定が期待の1つに決まることを確かめる
    func testTheDerivedVerdictDoesNotDependOnArrivalOrder() {
        let boot = "this-boot"
        func obs(_ mono: UInt64, _ source: FMLiveness.Source = .call, wall: Double? = nil) -> FMLiveness.Observation {
            FMLiveness.Observation(stamp: FMLiveness.Stamp(boot: boot, mono: mono), checkedAt: wall ?? Double(mono), source: source)
        }
        typealias Step = (FMLiveness.Observation, FMLiveness.ObservationKind)
        let cases: [(name: String, steps: [Step], expected: FMLiveness.State)] = [
            ("成功の後の失敗が2件だけ", [(obs(10), .callFailure), (obs(20), .alive), (obs(30), .callFailure), (obs(40), .callFailure)], .alive),
            ("成功の後に失敗が3件", [(obs(10), .callFailure), (obs(20), .alive), (obs(30), .callFailure),
                                (obs(40), .callFailure), (obs(50), .callFailure)], .dead),
            ("新しい生の後の古いプローブの死", [(obs(10, .probe), .alive), (obs(30, .probe), .alive), (obs(20, .probe), .deadDirect)], .alive),
            ("実呼び出しの死・新しい availability の死・古い成功",
             [(obs(30), .callFailure), (obs(35), .callFailure), (obs(40), .callFailure),
              (obs(50, .availability), .deadDirect), (obs(20), .alive)], .dead),
            ("全部の失敗より前の成功", [(obs(10), .callFailure), (obs(30), .callFailure), (obs(40), .callFailure), (obs(5), .alive)], .dead),
            // 壁時計が単調時刻と逆に並ぶ(時計が戻った): 判定は単調時刻だけで決まる
            ("壁時計の逆転", [(obs(10, .probe, wall: 300), .alive), (obs(20, .probe, wall: 200), .alive),
                          (obs(15, .probe, wall: 250), .deadDirect)], .alive),
            ("壁時計の逆転・失敗", [(obs(10, wall: 300), .alive), (obs(20, wall: 50), .callFailure),
                             (obs(30, wall: 40), .callFailure), (obs(40, wall: 30), .callFailure)], .dead),
        ]
        func permutations<T>(_ items: [T]) -> [[T]] {
            guard items.count > 1 else { return [items] }
            return items.indices.flatMap { i -> [[T]] in
                var rest = items
                let head = rest.remove(at: i)
                return permutations(rest).map { [head] + $0 }
            }
        }
        for item in cases {
            var seen = Set<String>()
            for order in permutations(item.steps) {
                var basis = FMLiveness.Basis()
                for (observation, kind) in order { FMLiveness.insert(observation, kind: kind, into: &basis) }
                seen.insert(FMLiveness.derive(basis)?.state.rawValue ?? "nil")
            }
            XCTAssertEqual(seen, [item.expected.rawValue], "\(item.name): 着く順で判定が変わった")
        }
    }

    /// 畳まれた(同じ状態・書いたばかり)生の観測でも連続失敗は戻す —— 畳むのはディスクへの書き直しであって観測ではない
    func testCoalescedAliveStillResetsTheFailureStreak() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: true)
            for _ in 0..<(FMBreaker.threshold - 1) {
                FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            }
            FMLiveness.record(path: .vision, state: .alive, source: .probe, ms: 600, observed: .now())
            FMHealth.record(kind: "occlusion", path: .vision, ms: 90, ok: false, error: "boom")
            XCTAssertNotEqual(FMLiveness.read()?.vision?.state, .dead, "畳まれた生の観測が連続失敗を戻さなかった")
        }
    }

    /// **連続失敗は機械全体で数える**: シナリオは1本ごとに別プロセスで走るので、プロセス内で数えると
    /// 閾値に届かず死を記録しない。別プロセスを、プロセス内の記憶を捨てることで模す
    func testFailureStreakSurvivesAcrossProcesses() throws {
        try SharedResource.hostCaches.locked {
            FMHealth.reset()
            defer { FMHealth.reset() }
            for _ in 0..<3 {
                FMLiveness.resetWriteMemo()
                FMHealth.record(kind: "occlusion", path: .vision, ms: 16000, ok: false, error: "boom")
            }
            XCTAssertEqual(FMLiveness.read()?.vision?.state, .dead,
                           "プロセスを跨いだ3回の連続失敗で死と記録されるはず")
        }
    }

    /// 門が読む判定: 新しい死だけが「呼ばない」。古い死・生・不明は呼んで確かめる
    func testIsKnownDeadOnlyForAFreshDeath() throws {
        try SharedResource.hostCaches.locked {
            let now = Date()
            XCTAssertFalse(FMLiveness.isKnownDead(.vision, now: now), "記録が無い = 不明 = 呼ぶ")
            FMLiveness.record(path: .vision, state: .dead, source: .probe, error: "boom", now: now, observed: .at(now))
            XCTAssertTrue(FMLiveness.isKnownDead(.vision, now: now))
            XCTAssertFalse(FMLiveness.isKnownDead(.text, now: now), "経路は独立")
            XCTAssertFalse(FMLiveness.isKnownDead(.vision, now: now.addingTimeInterval(121)),
                           "120 秒より古い死は不明 = 呼んで確かめる")
            FMLiveness.resetWriteMemo()
            FMLiveness.record(path: .vision, state: .alive, source: .probe,
                              now: now.addingTimeInterval(1), observed: .at(now.addingTimeInterval(1)))
            XCTAssertFalse(FMLiveness.isKnownDead(.vision, now: now.addingTimeInterval(1)))
        }
    }

    /// 着地しなかった書き込みが、その直後の正当な書き込みを畳んで消さない。
    /// 控えを「書こうとした回」で進めると、ディスクに1度も着地しない状態が続く
    func testARejectedWriteDoesNotSwallowTheNextOne() throws {
        try SharedResource.hostCaches.locked {
            let now = Date()
            FMLiveness.record(path: .text, state: .alive, source: .probe, now: now, observed: .at(now))
            // 自分より新しい観測が既に居るので、この書き込みは着地しない
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "stale",
                              now: now.addingTimeInterval(-1), observed: .at(now.addingTimeInterval(-1)))
            // coalesce の窓(5秒)の内側に来る正当な観測。**これは着地しなければならない**
            FMLiveness.record(path: .text, state: .dead, source: .probe, error: "real",
                              now: now.addingTimeInterval(1), observed: .at(now.addingTimeInterval(1)))
            XCTAssertEqual(FMLiveness.read()?.text?.error, "real")
        }
    }

    /// **読み→畳み→書きは flock で排他する**(規律 ④「もう片方の経路を消さない」は複数の
    /// 書き手が同時に走るときにも成り立たなければならない)。text と vision を別スレッドが
    /// 交互の状態で書き続け、**自分の record が戻った直後にディスクの自分の経路が自分の観測
    /// 以上であること**を毎回見る —— 排他が無いと、相手が古い記録を読んで畳んだ rename で
    /// 自分の経路が1つ前へ戻る(それが見えるのはこの直後の読みだけ)
    func testConcurrentWritersNeverRevertEachOthersPath() throws {
        try SharedResource.hostCaches.locked {
            let base = Date().timeIntervalSince1970
            let iterations = 200
            let reverted = LockedBox<[String]>([])
            let group = DispatchGroup()
            for path in [FMLiveness.Path.text, .vision] {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    for i in 0..<iterations {
                        // 状態を交互にして coalesce(同じ状態の書き直しを畳む)を通さない
                        let state: FMLiveness.State = i % 2 == 0 ? .alive : .dead
                        let checkedAt = base + Double(i)
                        FMLiveness.record(path: path, state: state, source: .probe,
                                          error: state == .dead ? "boom" : nil,
                                          now: Date(timeIntervalSince1970: checkedAt), observed: .at(Date(timeIntervalSince1970: checkedAt)))
                        let onDisk = FMLiveness.read()?[path]?.checkedAt ?? -1
                        if onDisk < checkedAt {
                            reverted.mutate { $0.append("\(path.rawValue) #\(i): disk=\(onDisk) < mine=\(checkedAt)") }
                        }
                    }
                }
            }
            group.wait()
            XCTAssertEqual(reverted.value, [], "相手の書き込みが自分の経路を古い値へ戻した")
            let final = FMLiveness.read()
            XCTAssertEqual(final?.text?.checkedAt, base + Double(iterations - 1))
            XCTAssertEqual(final?.vision?.checkedAt, base + Double(iterations - 1))
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
            fmCalls: 0, fmFailures: 0, fmTotalMs: 0,
            visionCalls: 0, visionFailures: 0, visionTotalMs: 0, ocrCompiling: 0, fmLiveness: dead).encodedLine()
        let json = try XCTUnwrap(line)
        XCTAssertTrue(json.contains("\"fmVisionState\":\"dead\""), json)
        XCTAssertTrue(json.contains("\"fmTextState\":null"), "観測の無い経路は null(不明)。\(json)")
        XCTAssertTrue(json.contains("\"fmDeadReason\":\"vision: ANE 0x10006"
                                    + FMLiveness.Reading.deadSummaryNote + "\""), json)
        XCTAssertTrue(json.contains("\"fmCheckedAt\":1700000000"), json)

        let quiet = HostMetricsSample(
            ts: 1, cpu: nil, gpu: nil, memUsedBytes: nil, memTotalBytes: nil,
            fmCalls: 0, fmFailures: 0, fmTotalMs: 0,
            visionCalls: 0, visionFailures: 0, visionTotalMs: 0, ocrCompiling: 0).encodedLine()
        XCTAssertTrue(try XCTUnwrap(quiet).contains("\"fmDeadReason\":null"),
                      "死活を渡さない呼び出し元は不明のまま(欄は必ず出す)")
    }

    /// 1Hz で流す行はエラー全文を載せない(切り詰めの上限が効いている)
    func testHostMetricsDeadReasonIsTruncated() throws {
        let long = String(repeating: "x", count: 900)
        let sample = HostMetricsSample(
            ts: 1, cpu: nil, gpu: nil, memUsedBytes: nil, memTotalBytes: nil,
            fmCalls: nil, fmFailures: nil, fmTotalMs: nil,
            visionCalls: nil, visionFailures: nil, visionTotalMs: nil, ocrCompiling: 0,
            fmLiveness: FMLiveness.Reading(
                text: FMLiveness.Verdict(state: .dead, checkedAt: 1, source: .probe, error: long),
                vision: nil))
        XCTAssertEqual(sample.fmDeadReason?.count, HostMetricsSample.deadReasonLimit)
    }
}
