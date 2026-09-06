// リモート監視の子が短時間で死に続けたあと**恒久停止しない**こと(CLAUDE.md §リモートのデバイスの
// 監視と配信)。VSCode を開いたときランナーが寝ている / 再起動中だと ssh ConnectTimeout で子が
// 約 10 秒で死に、約 40 秒で速い段を使い切る。そこで return すると、ランナーが戻っても台は
// `state:"unknown"`・占有は `observed:false` = 配信が畳まれたまま `api monitor` の再起動まで戻らない
// (2026-09-06 に実際に踏んだ)。期待値は production の定数を写さず**リテラルで書く**
// (定数を変えたときにこのテストが黙って追随しない = 根拠の書き直しを強制する)。

import XCTest
import FTCore
import FTTestSupport
@testable import fleetest

final class RemoteMonitorFanoutRetryTests: XCTestCase {

    // MARK: - 純粋関数(次の一手)

    /// 速い段: すぐ死ぬたびに回数が増え、待ちは 5 → 15 と伸び、3 回目で諦める(60 秒・回数 0)
    func testQuickFailuresEscalateThenFallToTheSlowPhase() {
        let first = RemoteMonitorFanout.retryPlan(quickFailures: 0, elapsed: 1)
        XCTAssertEqual(first, .init(quickFailures: 1, delaySeconds: 5, gaveUp: false))
        let second = RemoteMonitorFanout.retryPlan(quickFailures: 1, elapsed: 1)
        XCTAssertEqual(second, .init(quickFailures: 2, delaySeconds: 15, gaveUp: false))
        let third = RemoteMonitorFanout.retryPlan(quickFailures: 2, elapsed: 1)
        XCTAssertEqual(third, .init(quickFailures: 0, delaySeconds: 60, gaveUp: true),
                       "諦めても回数は 0 に戻す = 次は速い段からやり直す")
    }

    /// 15 秒以上生きていた子の死は「設定は通っていた」= 回数を 0 に戻し、最短の 2 秒で張り直す
    func testLongLivedChildResetsTheStreak() {
        let plan = RemoteMonitorFanout.retryPlan(quickFailures: 2, elapsed: 15)
        XCTAssertEqual(plan, .init(quickFailures: 0, delaySeconds: 2, gaveUp: false))
    }

    /// 速い段の境界: 14.9 秒はクイック(15 秒未満)
    func testJustUnderTheQuickWindowStillCounts() {
        XCTAssertEqual(RemoteMonitorFanout.retryPlan(quickFailures: 0, elapsed: 14.9).quickFailures, 1)
    }

    // MARK: - 監督ループ(ssh を張らずに差し替え口で回す)

    /// rsync 失敗 → 60 秒待って rsync からやり直す / 子が 3 回すぐ死ぬ → 60 秒待って
    /// **rsync から**速い段をやり直す(再起動で作業木が消えていても拾える)。stop() で即抜ける
    func testGiveUpIsFollowedBySlowRetryThatReentersTheFastPhase() {
        let events = LockedBox<[String]>([])
        let logs = LockedBox<[String]>([])
        let relayed = LockedBox<[String]>([])
        let syncCalls = LockedBox<Int>(0)
        let childCalls = LockedBox<Int>(0)
        let holder = LockedBox<RemoteMonitorFanout?>(nil)
        let fanout = RemoteMonitorFanout(
            machines: ["M1Ultra"], project: "P", profile: nil, interval: 2, maxWidth: 960,
            log: { line in logs.mutate { $0.append(line) } },
            relayLine: { line in relayed.mutate { $0.append(line) } },
            projectSync: { _ in
                syncCalls.mutate { $0 += 1 }
                let n = syncCalls.value
                events.mutate { $0.append("sync") }
                // 最初の 2 回は rsync が落ちる(ランナーが寝ている形)
                return n <= 2 ? "rsync failed" : nil
            },
            childRunner: { _ in
                childCalls.mutate { $0 += 1 }
                let n = childCalls.value
                events.mutate { $0.append("child") }
                // 5 本目の子で stop() = 「戻った」あとの実行に入ったことを確かめて終える
                if n == 5 { holder.value?.stop() }
            },
            sleepSlice: { events.mutate { $0.append("z") } })
        holder.mutate { $0 = fanout }

        fanout.superviseMachine("M1Ultra")

        let z60 = Array(repeating: "z", count: 60)
        var expected: [String] = []
        expected += ["sync"] + z60            // rsync 失敗 → 低速リトライ
        expected += ["sync"] + z60            // もう1回落ちる → 低速リトライ
        expected += ["sync"]                  // 通った
        expected += ["child"] + Array(repeating: "z", count: 5)
        expected += ["child"] + Array(repeating: "z", count: 15)
        expected += ["child"] + z60           // 3 回目 → 諦めて低速リトライ
        expected += ["sync", "child"]         // **rsync から**やり直す(4 本目もすぐ死ぬ)
        expected += Array(repeating: "z", count: 5) + ["child"]  // 待ちは 5 秒 = 速い段の頭に戻っている。5 本目で stop
        XCTAssertEqual(events.value, expected)

        // 諦めのログは 1 周期に 1 行だけ(何日寝ていても spam にならない)
        let giveUps = logs.value.filter { $0.contains("Giving up on M1Ultra for now") }
        XCTAssertEqual(giveUps.count, 1, logs.value.joined(separator: "\n"))
        XCTAssertTrue(giveUps[0].contains("retrying every 60s"), giveUps[0])
        let syncFailures = logs.value.filter { $0.contains("rsync failed") }
        XCTAssertEqual(syncFailures.count, 2)
        XCTAssertTrue(syncFailures.allSatisfy { $0.contains("retrying every 60s") }, syncFailures.joined(separator: "\n"))

        // 諦めている間も中継は「未観測」のまま(状態を偽らない): rsync 失敗 2 回 + 子の死 5 回
        let unobserved = relayed.value.filter { $0.contains(#""observed":false"#) && $0.contains(#""machine":"M1Ultra""#) }
        XCTAssertEqual(unobserved.count, 7, relayed.value.joined(separator: "\n"))
        XCTAssertTrue(fanout.snapshot().isEmpty, "子が死んだあとの台を残さない")
    }

    /// 低速リトライの sleep の最中に stop() が来たら残りを捨てる(`api monitor` は stdin EOF で
    /// 即終わる契約。60 秒の一枚岩の sleep だと終了が最長 60 秒遅れる)
    func testStoppingDuringTheSlowSleepEndsPromptly() {
        let slices = LockedBox<Int>(0)
        let holder = LockedBox<RemoteMonitorFanout?>(nil)
        let fanout = RemoteMonitorFanout(
            machines: ["M1Ultra"], project: "P", profile: nil, interval: 2, maxWidth: 960,
            log: { _ in }, relayLine: { _ in },
            sleepSlice: {
                slices.mutate { $0 += 1 }
                if slices.value == 2 { holder.value?.stop() }
            })
        holder.mutate { $0 = fanout }
        fanout.sleepUnlessStopping(60)
        XCTAssertEqual(slices.value, 2, "2 刻み目で stop したら 3 刻み目には入らない")
    }

    /// stop 済みなら 1 刻みも眠らない(supervise の while 条件と同じ向き)
    func testAlreadyStoppedDoesNotSleepAtAll() {
        let slices = LockedBox<Int>(0)
        let fanout = RemoteMonitorFanout(
            machines: ["M1Ultra"], project: "P", profile: nil, interval: 2, maxWidth: 960,
            log: { _ in }, relayLine: { _ in },
            sleepSlice: { slices.mutate { $0 += 1 } })
        fanout.stop()
        fanout.sleepUnlessStopping(60)
        XCTAssertEqual(slices.value, 0)
    }
}
