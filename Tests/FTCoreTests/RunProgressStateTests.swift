// RunProgressState(RunOrchestrator の run 進捗の記帳。docs/design.md §18)の検証。
// 守るもの: ①前回と同じ内容なら書かない(壁時計だけが進む周期で emit させない、の actor 側の砦)
// ②再キュー(laneIdled)は done/failed を増やさない ③scenarioFinished は done を必ず、
// 失敗なら failed も増やす ④finish() は remove を呼ぶ ⑤残り見積もり(§18.4)は進捗とともに減る
// (RunProgressEstimate の式そのものは RunProgressEstimateTests が固定するので、ここでは
// scenarioStarted/scenarioFinished/laneIdled が pendingCounts を正しく出し入れしているかだけを見る)。

import XCTest
@testable import FTCore

final class RunProgressStateTests: XCTestCase {

    private final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var writes: [RunProgressRecord] = []
        private(set) var removeCount = 0
        func recordWrite(_ record: RunProgressRecord) {
            lock.lock(); writes.append(record); lock.unlock()
        }
        func recordRemove() {
            lock.lock(); removeCount += 1; lock.unlock()
        }
    }

    private func makeState(
        _ journal: Journal, total: Int = 3,
        estimates: [RunProgressEstimate.ScenarioKey: Double] = [:],
        pendingScenarios: [RunProgressEstimate.ScenarioKey] = [],
        supply: RunSupplyProgress? = nil
    ) -> RunProgressState {
        RunProgressState(pid: 4242, runID: "r1", runGroup: nil, issuer: "alice@air",
                         project: "ec-mobile", profile: "ios-smoke", startedAt: Date(), total: total,
                         estimates: estimates, pendingScenarios: pendingScenarios, supply: supply,
                         write: { journal.recordWrite($0) }, remove: { journal.recordRemove() })
    }

    /// compile-ocr の待ちの間は段階が "compiling" で残りを出さない(読み手は受信時点の残りから秒読みするので、
    /// 出すと何も動いていない間に減っていく)。待ちを抜けたら "running" と残りが戻る
    func testCompileWaitShowsCompilingWithoutEtaThenRunning() async {
        let journal = Journal()
        let key = RunProgressEstimate.ScenarioKey(scenarioID: "05_検索", platform: "ios")
        let state = makeState(journal, total: 2, estimates: [key: 10_000], pendingScenarios: [key, key])
        await state.ocrCompileWaitBegan()
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.ocrCompileWaitBegan()
        await state.laneJoined(key: "UDID-B", name: "iPhone 17-02", platform: "ios")
        // 2本目の待ち始めは内容が変わらないので書かない(同じ record は書かない規律)
        XCTAssertEqual(journal.writes.map(\.phase), ["compiling", "compiling", "compiling"],
                       "最初の記帳から compiling(running を一瞬挟まない)")
        XCTAssertTrue(journal.writes.allSatisfy { $0.etaSeconds == nil })
        await state.ocrCompileWaitEnded()
        XCTAssertEqual(journal.writes.last?.phase, "compiling", "待っているレーンが残っている間は compiling のまま")
        await state.ocrCompileWaitEnded()
        XCTAssertEqual(journal.writes.last?.phase, "running")
        XCTAssertEqual(journal.writes.last?.etaSeconds, 10, "2本×10秒 ÷ 2レーン")
    }

    /// 全シナリオの後の動画の切り出しの間は進みを載せて残りを出さない(phase は running のまま)
    func testVideoClipsProgressIsCarriedAndHidesEta() async {
        let journal = Journal()
        let key = RunProgressEstimate.ScenarioKey(scenarioID: "05_検索", platform: "ios")
        let state = makeState(journal, total: 1, estimates: [key: 10_000], pendingScenarios: [key])
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        XCTAssertNil(journal.writes.last?.videoClips)
        XCTAssertNotNil(journal.writes.last?.etaSeconds)
        await state.videoClipsProgress(done: 0, total: 2)
        await state.videoClipsProgress(done: 1, total: 2)
        XCTAssertEqual(journal.writes.suffix(2).map(\.videoClips),
                       [RunProgressVideoClips(done: 0, total: 2), RunProgressVideoClips(done: 1, total: 2)])
        XCTAssertNil(journal.writes.last?.etaSeconds)
        XCTAssertEqual(journal.writes.last?.phase, "running")
    }

    func testJoiningTheSameLaneWithIdenticalContentDoesNotWriteTwice() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        XCTAssertEqual(journal.writes.count, 1, "内容が変わっていない2回目は書かないはず")
    }

    func testScenarioStartedThenFinishedWritesOnEachRealChange() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.scenarioFinished(laneKey: "UDID-A", passed: true)
        XCTAssertEqual(journal.writes.count, 3)
        XCTAssertEqual(journal.writes.last?.done, 1)
        XCTAssertEqual(journal.writes.last?.failed, 0)
        XCTAssertNil(journal.writes.last?.lanes.first?.scenario, "終了後は待機中(scenario nil)へ戻る")
    }

    func testScenarioFinishedWithFailureIncrementsBothDoneAndFailed() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioFinished(laneKey: "UDID-A", passed: false)
        XCTAssertEqual(journal.writes.last?.done, 1)
        XCTAssertEqual(journal.writes.last?.failed, 1)
    }

    /// 再キュー(結果を捨てて別デバイスへ回す)は**まだ終わっていない** —— done/failed を増やさない
    func testLaneIdledDoesNotCountAsFinished() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.laneIdled(laneKey: "UDID-A")
        XCTAssertEqual(journal.writes.last?.done, 0)
        XCTAssertEqual(journal.writes.last?.failed, 0)
        XCTAssertNil(journal.writes.last?.lanes.first?.scenario)
    }

    func testLaneLeftRemovesTheLaneFromTheSnapshot() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.laneLeft(key: "UDID-A")
        XCTAssertEqual(journal.writes.last?.lanes, [])
    }

    /// total は run 開始時に確定した値のまま —— scenarioFinished を何度呼んでも動かない
    func testTotalNeverChanges() async {
        let journal = Journal()
        let state = makeState(journal, total: 12)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        for _ in 0..<3 {
            await state.scenarioFinished(laneKey: "UDID-A", passed: true)
        }
        XCTAssertEqual(journal.writes.last?.total, 12)
    }

    /// RunProgressState が書く record は常に "running"("preparing" は供給フェーズが
    /// RunOrchestrator の外(ProfileRunner/ApiRunCommand)で書く別の記録)
    func testWrittenRecordsAreAlwaysPhaseRunning() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        XCTAssertEqual(journal.writes.last?.phase, "running")
    }

    /// 箱の snapshot が record の supply に載る(箱が無ければ空)
    func testFlushCarriesTheSupplySnapshot() async {
        let journal = Journal()
        let box = RunSupplyProgress()
        box.set(name: "iPhone 17-02", platform: "ios", step: .bridge)
        box.set(name: "Pixel 9-01", platform: "android", step: .ready)
        let state = makeState(journal, supply: box)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        // 名前順(コードポイント順 = 大文字の "P" が小文字の "i" より先)
        XCTAssertEqual(journal.writes.last?.supply, [
            RunProgressSupply(name: "Pixel 9-01", platform: "android", step: "ready"),
            RunProgressSupply(name: "iPhone 17-02", platform: "ios", step: "bridge"),
        ])
        let withoutBox = Journal()
        let plain = makeState(withoutBox)
        await plain.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        XCTAssertEqual(withoutBox.writes.last?.supply, [])
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// 最初の書き込みの後は、箱の変更で書き直す(混在 run で iOS が後から合流中の段階)。
    /// 最初の書き込みの前は通知を奪わない(準備中の書き手が続ける)
    func testSupplyChangeRewritesOnlyAfterTheFirstWrite() async {
        let journal = Journal()
        let box = RunSupplyProgress()
        let preparingCalls = LockedValue(0)
        box.setOnChange(owner: ObjectIdentifier(box)) { preparingCalls.withLock { $0 += 1 } }
        let state = makeState(journal, supply: box)
        box.set(name: "iPhone 17-01", platform: "ios", step: .booting)
        XCTAssertEqual(preparingCalls.value, 1, "最初の書き込み前は準備中の書き手の通知が生きている")
        XCTAssertEqual(journal.writes.count, 0)

        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        XCTAssertEqual(journal.writes.count, 1)
        box.set(name: "iPhone 17-01", platform: "ios", step: .ready)
        let rewritten = await waitUntil { journal.writes.count == 2 }
        XCTAssertTrue(rewritten, "箱の変更で台帳を書き直す")
        XCTAssertEqual(journal.writes.last?.supply.map(\.step), ["ready"])
        XCTAssertEqual(preparingCalls.value, 1, "引き継いだ後は準備中の書き手へ通知しない")
        // 同じ内容は箱が通知しない = 書き直さない
        box.set(name: "iPhone 17-01", platform: "ios", step: .ready)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(journal.writes.count, 2)
    }

    /// finish() の後に箱が変わっても台帳を作り直さない
    func testSupplyChangeAfterFinishDoesNotRewrite() async {
        let journal = Journal()
        let box = RunSupplyProgress()
        let state = makeState(journal, supply: box)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.finish()
        box.set(name: "iPhone 17-01", platform: "ios", step: .installing)
        await state.supplyChanged()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(journal.writes.count, 1)
    }

    func testFinishCallsRemove() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.finish()
        XCTAssertEqual(journal.removeCount, 1)
    }

    /// 3本 × 10秒・1レーン。join 直後は makespan の下界 = 総和(30秒)。1本終わるたびに
    /// 残り(pendingCounts)が1つ減り、etaSeconds も減る(RunProgressEstimate の式は
    /// RunProgressEstimateTests が別途固定するので、ここでは配線 —— scenarioStarted で
    /// pending から引き、scenarioFinished では戻さない —— だけを見る)
    func testEtaSecondsDecreasesAsScenariosFinish() async {
        let journal = Journal()
        let key = RunProgressEstimate.ScenarioKey(scenarioID: "05_検索", platform: "ios")
        let state = makeState(journal, total: 3,
                              estimates: [key: 10_000], pendingScenarios: [key, key, key])
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        XCTAssertEqual(journal.writes.last?.etaSeconds, 30,
                       "3本×10秒・1レーンの下界は総和(max(10, 30/1))")

        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.scenarioFinished(laneKey: "UDID-A", passed: true)
        XCTAssertEqual(journal.writes.last?.etaSeconds, 20, "1本終わって残り2本×10秒")

        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.scenarioFinished(laneKey: "UDID-A", passed: true)
        XCTAssertEqual(journal.writes.last?.etaSeconds, 10, "2本終わって残り1本×10秒")
    }

    /// 再キュー(laneIdled)は pending へ戻す —— 見積もりが「もう終わった」ぶんだけ
    /// 減ったまま戻らない、という誤りを防ぐ
    func testLaneIdledRestoresTheScenarioToPending() async {
        let journal = Journal()
        let key = RunProgressEstimate.ScenarioKey(scenarioID: "05_検索", platform: "ios")
        let state = makeState(journal, total: 1, estimates: [key: 10_000], pendingScenarios: [key])
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.laneIdled(laneKey: "UDID-A")
        XCTAssertEqual(journal.writes.last?.etaSeconds, 10,
                       "振り直しでまだ未着手ぶんに戻っている(消えていない)")
    }

    // MARK: - 詰まりの事実(§18.1 段6。判定・閾値は作らない。回数を数えるだけ)

    /// 再キュー(laneIdled)は requeued を1増やす。laneDropouts は増えない
    func testLaneIdledIncrementsRequeuedOnly() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.laneIdled(laneKey: "UDID-A")
        XCTAssertEqual(journal.writes.last?.requeued, 1)
        XCTAssertEqual(journal.writes.last?.laneDropouts, 0)
    }

    /// レーン離脱(laneLeft)は laneDropouts を1増やす。requeued は増えない
    func testLaneLeftIncrementsLaneDropoutsOnly() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.laneLeft(key: "UDID-A")
        XCTAssertEqual(journal.writes.last?.laneDropouts, 1)
        XCTAssertEqual(journal.writes.last?.requeued, 0)
    }

    /// 通常の完了(scenarioFinished)ではどちらも増えない
    func testNormalCompletionDoesNotIncrementEitherCounter() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.scenarioFinished(laneKey: "UDID-A", passed: true)
        XCTAssertEqual(journal.writes.last?.requeued, 0)
        XCTAssertEqual(journal.writes.last?.laneDropouts, 0)
    }

    /// 累計は増え続ける(2回目の再キュー・離脱でも1ずつ増える)
    func testRequeuedAndLaneDropoutsAccumulateAcrossMultipleEvents() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.laneIdled(laneKey: "UDID-A")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.laneIdled(laneKey: "UDID-A")
        XCTAssertEqual(journal.writes.last?.requeued, 2)

        await state.laneJoined(key: "UDID-B", name: "iPhone 17-02", platform: "ios")
        await state.laneLeft(key: "UDID-B")
        XCTAssertEqual(journal.writes.last?.laneDropouts, 1)
    }

    // MARK: - expectedSeconds(§18.5 段6。実績表からレーン単位で引く。新しい I/O は足さない)

    /// シナリオ開始時、実績表にあれば expectedSeconds を秒(切り上げ)で持つ
    func testScenarioStartedSetsExpectedSecondsFromTheEstimateTable() async {
        let journal = Journal()
        let key = RunProgressEstimate.ScenarioKey(scenarioID: "05_検索", platform: "ios")
        let state = makeState(journal, estimates: [key: 70_500])
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        XCTAssertEqual(journal.writes.last?.lanes.first?.expectedSeconds, 71,
                       "70.5秒 → 切り上げで71秒(RunProgressEstimate と同じ丸め)")
    }

    /// 実績表に無い(初見のシナリオ・実績ゼロの run)なら nil —— 推測値を出さない
    func testScenarioStartedLeavesExpectedSecondsNilWithoutAnEstimate() async {
        let journal = Journal()
        let state = makeState(journal)
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        XCTAssertNil(journal.writes.last?.lanes.first?.expectedSeconds)
    }

    /// 待機中のレーン(join 直後・再キュー後・完了直後)は expectedSeconds も nil
    func testIdleLanesHaveNilExpectedSeconds() async {
        let journal = Journal()
        let key = RunProgressEstimate.ScenarioKey(scenarioID: "05_検索", platform: "ios")
        let state = makeState(journal, estimates: [key: 10_000])
        await state.laneJoined(key: "UDID-A", name: "iPhone 17-01", platform: "ios")
        XCTAssertNil(journal.writes.last?.lanes.first?.expectedSeconds, "join 直後は待機中")
        await state.scenarioStarted(laneKey: "UDID-A", scenario: "05_検索", at: Date())
        await state.scenarioFinished(laneKey: "UDID-A", passed: true)
        XCTAssertNil(journal.writes.last?.lanes.first?.expectedSeconds, "完了後は待機中へ戻る")
    }
}
