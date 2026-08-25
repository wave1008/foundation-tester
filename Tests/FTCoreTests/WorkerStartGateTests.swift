// ワーカー起動の門(間隔 + CPU)。実時間を進めずに全分岐を通す。
//
// 守る性質:
// - 先頭 2 本は**間隔を待たない**が、**CPU の門は通る**(同時起動枠。ユーザー指示)
// - 3本目以降は間隔を待ち、**そのうえで CPU が上限未満になるまで**待つ
// - 上限まで空かなければ**諦めて素通しし、以降は CPU を見ない**(立ち上がりが延び続けない)
// - 計測できない環境では素通しする(測れないことで run を止めない)

import XCTest
@testable import FTCore

final class WorkerStartGateTests: XCTestCase {

    /// 台本どおりに CPU 値を返し、要求された sleep を記録する
    private final class Fixture {
        var loads: [Double?]
        private(set) var slept: [Double] = []
        private(set) var samples = 0
        init(_ loads: [Double?]) { self.loads = loads }

        func sample() -> Double? {
            samples += 1
            // 台本を使い切ったら最後の値を返し続ける(無限ループの検出を待ちに化けさせない)
            guard !loads.isEmpty else { return 1.0 }
            return loads.count == 1 ? loads[0] : loads.removeFirst()
        }
        func sleep(_ seconds: Double) async { slept.append(seconds) }
    }

    private func gate(_ fixture: Fixture, interval: Double = 1.5, head: Int = 2,
                      ceiling: Double = 1.0, cap: Double = 30.0,
                      poll: Double = 0.5) -> WorkerStartGate {
        WorkerStartGate(intervalSeconds: interval, simultaneousHead: head, ceiling: ceiling,
                        cap: cap, pollInterval: poll,
                        sampleCPU: { fixture.sample() }, sleep: { await fixture.sleep($0) })
    }

    // MARK: - 先頭の同時起動枠

    /// 空いていれば先頭2本は**間隔を待たずに**開始する
    func testTheFirstTwoWorkersSkipTheIntervalWhenTheHostIsIdle() async {
        let fixture = Fixture([0.3])
        let subject = gate(fixture)
        let first = await subject.waitForTurn()
        let second = await subject.waitForTurn()
        XCTAssertEqual(first, .interval(waited: 0))
        XCTAssertEqual(second, .interval(waited: 0))
        XCTAssertTrue(fixture.slept.isEmpty, "同時起動枠で間隔を待っている: \(fixture.slept)")
        XCTAssertEqual(fixture.samples, 2, "同時起動枠で CPU を見ていない")
    }

    /// **飽和していれば先頭の1本目も待つ**(ユーザー指示)。
    /// 先頭免除は「間隔を空けない」であって「飽和したホストへ撃ってよい」ではない
    func testTheVeryFirstWorkerStillWaitsForASaturatedHost() async {
        let fixture = Fixture([1.0, 1.0, 0.6])
        let subject = gate(fixture)
        let first = await subject.waitForTurn()
        XCTAssertEqual(first, .waitedForCPU(waited: 1.0, load: 0.6))
        // 待ったのは CPU の門だけ(間隔 1.5 は入らない)
        XCTAssertEqual(fixture.slept, [0.5, 0.5])
    }

    // MARK: - 間隔

    /// 3本目以降は間隔を待つ。CPU が空いていれば**それ以上は待たない**
    func testThirdWorkerWaitsTheIntervalOnlyWhenTheHostIsIdle() async {
        let fixture = Fixture([0.4])
        let subject = gate(fixture)
        for _ in 0..<2 { await subject.waitForTurn() }
        let third = await subject.waitForTurn()
        XCTAssertEqual(third, .interval(waited: 1.5))
        XCTAssertEqual(fixture.slept, [1.5])
    }

    func testIntervalOfZeroSleepsNothingButStillChecksCPU() async {
        let fixture = Fixture([0.2])
        let subject = gate(fixture, interval: 0)
        for _ in 0..<2 { await subject.waitForTurn() }
        let third = await subject.waitForTurn()
        XCTAssertEqual(third, .interval(waited: 0))
        XCTAssertTrue(fixture.slept.isEmpty)
        // 3本 = 3回。先頭2本も CPU を見る
        XCTAssertEqual(fixture.samples, 3, "間隔 0 で CPU の門まで外れている")
    }

    // MARK: - CPU の門

    /// **飽和している間は開始しない**。空いたところで開始する
    func testItWaitsWhileTheHostIsSaturated() async {
        // 先頭2本ぶんのアイドル値を先に置く(先頭も CPU を見るので台本を食う)
        let fixture = Fixture([0.1, 0.1, 1.0, 1.0, 1.0, 0.7])
        let subject = gate(fixture)
        for _ in 0..<2 { await subject.waitForTurn() }
        let third = await subject.waitForTurn()
        XCTAssertEqual(third, .waitedForCPU(waited: 1.5 + 0.5 * 3, load: 0.7))
        XCTAssertEqual(fixture.slept, [1.5, 0.5, 0.5, 0.5])
    }

    /// 上限は **`<`**(ちょうど 100% は待つ・99% は通す)。境界で縛る
    func testTheCeilingIsExclusive() async {
        let saturated = Fixture([0.1, 0.1, 1.0, 0.99])
        let subject = gate(saturated)
        for _ in 0..<2 { await subject.waitForTurn() }
        let outcome = await subject.waitForTurn()
        XCTAssertEqual(outcome, .waitedForCPU(waited: 2.0, load: 0.99),
                       "100% ちょうどで開始している(飽和したまま起こす)")
    }

    /// 上限を下げれば早く止まる(対照実験のためのノブが効く)
    func testALowerCeilingWaitsForMoreHeadroom() async {
        let fixture = Fixture([0.1, 0.1, 0.9, 0.5])
        let subject = gate(fixture, ceiling: 0.8)
        for _ in 0..<2 { await subject.waitForTurn() }
        let outcome = await subject.waitForTurn()
        XCTAssertEqual(outcome, .waitedForCPU(waited: 2.0, load: 0.5))
    }

    // MARK: - 諦め(立ち上がりを延ばし続けない)

    func testItGivesUpAfterTheCapAndStopsGatingOnCPU() async {
        // 先頭2本は空いた状態で通し、3本目から永久に飽和させる(台本の最後は繰り返される)
        let fixture = Fixture([0.1, 0.1, 1.0])
        let subject = gate(fixture, cap: 2.0)
        for _ in 0..<2 { await subject.waitForTurn() }

        var logged: [String] = []
        let third = await subject.waitForTurn(log: { logged.append($0) })
        XCTAssertEqual(third, .gaveUpOnCPU(lastLoad: 1.0))
        // 上限ぶんだけ待った(間隔 1.5 + poll 0.5 × 4)
        XCTAssertEqual(fixture.slept, [1.5, 0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(logged.count, 1, "諦めたことを黙っている")
        // **添字で取らない** —— 黙る変異を当てたとき logged が空になり、テストが
        // アサーション失敗ではなく**クラッシュ**で落ちる(テストバイナリごと道連れになり
        // 同じ実行の他の結果が消える)
        XCTAssertEqual(logged.first?.contains("100%"), true, "\(logged)")

        // **以降は CPU を見ない** —— 見続けると 10 本で cap × 8 ぶん延びる
        let samplesSoFar = fixture.samples
        let sleptSoFar = fixture.slept.count
        let fourth = await subject.waitForTurn(log: { logged.append($0) })
        XCTAssertEqual(fourth, .interval(waited: 1.5))
        XCTAssertEqual(fixture.samples, samplesSoFar, "諦めた後も CPU を見ている")
        XCTAssertEqual(fixture.slept.count, sleptSoFar + 1, "諦めた後も CPU を待っている")
        XCTAssertEqual(logged.count, 1, "諦めの警告を毎回出している")
    }

    // MARK: - 直近値の使い回し(先頭2本を同時に保つ)

    /// **CPUSampler は連続で呼ぶと必ず nil**(差分が取れない。実測で確認)。
    /// 1本目が測った値を2本目が使い回せないと、先頭2本が測定窓のぶん離れて
    /// 「間隔0」が崩れる
    func testTheSecondHeadWorkerReusesTheLoadTheFirstOneMeasured() async {
        let fixture = Fixture([0.4, nil])       // 2回目以降は常に nil(連続呼び出し)
        let subject = gate(fixture)
        let first = await subject.waitForTurn()
        let second = await subject.waitForTurn()
        XCTAssertEqual(first, .interval(waited: 0))
        XCTAssertEqual(second, .interval(waited: 0), "2本目が測り直しで待たされている")
        XCTAssertTrue(fixture.slept.isEmpty, "先頭2本が離れている: \(fixture.slept)")
    }

    /// **1 窓より古い値は使わない**(「直近」でなくなったものを直近と偽らない)
    func testAStaleLoadIsNotReused() async {
        // 1本目が 0.4 を測り、2本目は nil を直近値で埋める(ここまで待ち 0)
        let fixture = Fixture([0.4, nil, nil, 0.3])
        let subject = gate(fixture)
        for _ in 0..<2 { await subject.waitForTurn() }
        XCTAssertTrue(fixture.slept.isEmpty, "先頭2本が待っている: \(fixture.slept)")
        // 3本目は間隔 1.5s(> 1 窓 0.5s)眠るので、直近値は**捨てて測り直す** ——
        // 使い回していれば 0.4 で即開始し、待ちは 1.5 のままになる
        let third = await subject.waitForTurn()
        XCTAssertEqual(third, .waitedForCPU(waited: 1.5 + 0.5, load: 0.3))
    }

    /// 測り直せたら「測れない」側の証拠を**白紙に戻す**。戻さないと、飽和したホストで
    /// 値と nil が交互に来たときに「測れない環境」と誤判定して門を素通しする
    func testAFreshReadingResetsTheStalenessClock() async {
        let fixture = Fixture([0.1, 0.1, 1.0, nil, nil, 0.3])
        let subject = gate(fixture)
        for _ in 0..<2 { await subject.waitForTurn() }
        let third = await subject.waitForTurn()
        XCTAssertEqual(third, .waitedForCPU(waited: 3.0, load: 0.3),
                       "測り直しの後も古い経過を持ち越し、測れない環境と誤判定して素通ししている")
    }

    // MARK: - 計測できない環境

    /// CPUSampler は**初回だけ必ず nil**(差分が取れない)。1回で諦めると門が常に無効になる
    func testASingleUnavailableSampleDoesNotDisableTheGate() async {
        let fixture = Fixture([0.1, 0.1, nil, 1.0, 0.3])
        let subject = gate(fixture)
        for _ in 0..<2 { await subject.waitForTurn() }
        let outcome = await subject.waitForTurn()
        XCTAssertEqual(outcome, .waitedForCPU(waited: 2.5, load: 0.3))
    }

    func testTwoUnavailableSamplesInARowPassThrough() async {
        let fixture = Fixture([nil, nil])
        let subject = gate(fixture)
        for _ in 0..<2 { await subject.waitForTurn() }
        let outcome = await subject.waitForTurn()
        XCTAssertEqual(outcome, .interval(waited: 2.0))
    }

    // MARK: - 上限値の読み取り(環境変数)

    func testCPUCeilingReadsFractionsAndPercentsAndRejectsJunk() {
        let key = "FT_WORKER_START_CPU_MAX"
        let original = ProcessInfo.processInfo.environment[key]
        defer {
            if let original { setenv(key, original, 1) } else { unsetenv(key) }
        }
        setenv(key, "0.85", 1)
        XCTAssertEqual(WorkerStagger.cpuCeiling, 0.85, accuracy: 0.0001)
        setenv(key, "85", 1)
        XCTAssertEqual(WorkerStagger.cpuCeiling, 0.85, accuracy: 0.0001)
        setenv(key, "1", 1)
        XCTAssertEqual(WorkerStagger.cpuCeiling, 1.0, accuracy: 0.0001)
        for junk in ["0", "-1", "abc", "1000", ""] {
            setenv(key, junk, 1)
            XCTAssertEqual(WorkerStagger.cpuCeiling, WorkerStagger.defaultCPUCeiling,
                           accuracy: 0.0001, "不正値 \"\(junk)\" で門を外している")
        }
        unsetenv(key)
        XCTAssertEqual(WorkerStagger.cpuCeiling, WorkerStagger.defaultCPUCeiling, accuracy: 0.0001)
    }

    /// 既定は **100%**(「飽和していなければ開始」)。詰まっている間だけ止める
    func testTheDefaultCeilingIsFullSaturation() {
        XCTAssertEqual(WorkerStagger.defaultCPUCeiling, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(WorkerStagger.cpuWaitCap, 0)
        XCTAssertGreaterThan(WorkerStagger.cpuPollInterval, 0)
        XCTAssertLessThan(WorkerStagger.cpuPollInterval, WorkerStagger.cpuWaitCap,
                          "ポーリング間隔が上限以上だと1度も見ないまま諦める")
    }
}
