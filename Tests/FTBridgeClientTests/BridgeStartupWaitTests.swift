// 起動待ちの「進み具合で延びる締切」(BridgeStartupWait)・結果の束の別名化と掃除・
// 死んだランナーの fail-fast(BridgeLauncher.waitUntilReady)。期待値はリテラル。

import XCTest
@testable import FTBridgeClient
import FTCore

final class BridgeStartupWaitTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - shouldKeepWaiting

    /// 進みが無ければ固定締切と同じ: 起動から budget を跨いだら諦める
    func testNoProgressGivesUpAtTheBudget() {
        XCTAssertTrue(BridgeStartupWait.shouldKeepWaiting(now: at(179), launchedAt: t0, lastProgressAt: nil,
                                                          suiteStartedAt: nil, budget: 180))
        XCTAssertFalse(BridgeStartupWait.shouldKeepWaiting(now: at(180), launchedAt: t0, lastProgressAt: nil,
                                                           suiteStartedAt: nil, budget: 180))
    }

    /// 印の前はログが伸びた時刻から数え直す(再起動直後の冷えた起動 = 138 秒で印、その後に HTTP)
    func testProgressSlidesTheDeadlineBeforeTheSuiteStarts() {
        XCTAssertTrue(BridgeStartupWait.shouldKeepWaiting(now: at(300), launchedAt: t0, lastProgressAt: at(150),
                                                          suiteStartedAt: nil, budget: 180))
        XCTAssertFalse(BridgeStartupWait.shouldKeepWaiting(now: at(330), launchedAt: t0, lastProgressAt: at(150),
                                                           suiteStartedAt: nil, budget: 180))
    }

    /// 印の後は進みで延ばさない(動いているのに答えないランナーを永久に待たない)
    func testAfterTheSuiteStartedProgressNoLongerExtends() {
        XCTAssertTrue(BridgeStartupWait.shouldKeepWaiting(now: at(319), launchedAt: t0, lastProgressAt: at(318),
                                                          suiteStartedAt: at(140), budget: 180))
        XCTAssertFalse(BridgeStartupWait.shouldKeepWaiting(now: at(320), launchedAt: t0, lastProgressAt: at(319),
                                                           suiteStartedAt: at(140), budget: 180))
    }

    func testSuiteMarkerIsTheXCTestLine() {
        XCTAssertEqual(BridgeStartupWait.suiteStartedMarker, "Test Suite 'All tests' started")
    }

    // MARK: - ランナーアプリの起動(ログが無音の間の進み)

    func testRunnerAppProcessIsRecognisedOnlyForTheSameSimulator() {
        let udid = "E38DCA93-95F2-4DDF-B1FE-29527205D3EE"
        let line = "/Users/x/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/8A5A/FleetestRunnerUITests-Runner.app/FleetestRunnerUITests-Runner"
        XCTAssertTrue(BridgeLauncher.isRunnerAppProcess(command: line, udid: udid))
        XCTAssertFalse(BridgeLauncher.isRunnerAppProcess(command: line, udid: "C96A69C4-FE49-42EE-8C7F-ED5F603C346B"), "隣の台のランナー")
        XCTAssertFalse(BridgeLauncher.isRunnerAppProcess(
            command: "/Users/x/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/1/FTE2ERN.app/FTE2ERN", udid: udid),
            "対象アプリはランナーではない")
    }

    // MARK: - 同時起動の枠(BridgeProvisioner.needsLaunchSlot / runWithLaunchSlots)

    func testColdSimulatorBootsTwoAtATime() {
        XCTAssertTrue(BridgeProvisioner.needsLaunchSlot(launchesInApp: false, launchesColdSimulator: true))
        XCTAssertTrue(BridgeProvisioner.needsLaunchSlot(launchesInApp: true, launchesColdSimulator: false))
        XCTAssertFalse(BridgeProvisioner.needsLaunchSlot(launchesInApp: false, launchesColdSimulator: false))
        XCTAssertEqual(BridgeProvisioner.launchSlotWidth, 2)
    }

    /// 枠に並ぶ台は同時2台まで・再利用だけの台は枠を待たずに全部走る(ブートの台が混ざっても2台ずつの列に並ばない)
    func testReuseOnlyDevicesDoNotQueueBehindLaunchSlots() async {
        let reuseCount = 3
        let state = LockedValue((reuseStarted: 0, slottedInFlight: 0, slottedPeak: 0, reuseSawAll: 0))
        let items = (0..<7).map { (item: $0, slotted: $0 >= reuseCount) }
        let outputs = await BridgeProvisioner.runWithLaunchSlots(items, width: 2) { index in
            if index < reuseCount {
                state.withLock { $0.reuseStarted += 1 }
                // 枠に並ばされていれば、再利用の3台がそろって走り出すことは無い(2秒で諦める)
                for _ in 0..<200 where state.withLock({ $0.reuseStarted }) < reuseCount {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                if state.withLock({ $0.reuseStarted }) == reuseCount { state.withLock { $0.reuseSawAll += 1 } }
            } else {
                state.withLock { $0.slottedInFlight += 1; $0.slottedPeak = max($0.slottedPeak, $0.slottedInFlight) }
                try? await Task.sleep(nanoseconds: 30_000_000)
                state.withLock { $0.slottedInFlight -= 1 }
            }
            return index * 10
        }
        XCTAssertEqual(outputs, [0, 10, 20, 30, 40, 50, 60], "結果は items の順")
        let final = state.withLock { $0 }
        XCTAssertEqual(final.reuseSawAll, reuseCount, "再利用だけの台が枠の列に並んだ")
        XCTAssertEqual(final.slottedPeak, 2, "枠に並ぶ台の同時数が2でない")
    }

    // MARK: - 結果の束

    func testResultBundleNamesForAPort() {
        XCTAssertTrue(BridgeLauncher.isResultBundle("bridge-8124.xcresult", port: 8124))
        XCTAssertTrue(BridgeLauncher.isResultBundle("bridge-8124-1757850000000.xcresult", port: 8124))
        XCTAssertFalse(BridgeLauncher.isResultBundle("bridge-81241.xcresult", port: 8124), "別ポートの前方一致")
        XCTAssertFalse(BridgeLauncher.isResultBundle("bridge-8125-1.xcresult", port: 8124))
        XCTAssertFalse(BridgeLauncher.isResultBundle("bridge-8124-1.log", port: 8124))
    }

    /// 同じポートの古い束だけを掃く。今回のぶんと隣のポートには触らない
    func testStaleBundlesExcludeTheCurrentOneAndOtherPorts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ftwait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["bridge-8124.xcresult", "bridge-8124-1.xcresult", "bridge-8124-2.xcresult",
                     "bridge-8125-1.xcresult", "notes.txt"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        let stale = BridgeLauncher.staleResultBundles(in: dir, port: 8124,
                                                      keeping: dir.appendingPathComponent("bridge-8124-2.xcresult"))
        XCTAssertEqual(stale.map(\.lastPathComponent), ["bridge-8124-1.xcresult", "bridge-8124.xcresult"])
    }

    func testLastLogLineSkipsTrailingBlankLines() {
        XCTAssertEqual(BridgeLauncher.lastLogLine(in: "a\nxcodebuild: error: Existing file\n\n  \n"),
                       "xcodebuild: error: Existing file")
        XCTAssertNil(BridgeLauncher.lastLogLine(in: nil))
        XCTAssertNil(BridgeLauncher.lastLogLine(in: "\n\n"))
    }

    // MARK: - 死んだランナーは締切を待たずに落ちる(実プロセス)

    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ftwait-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".fleetest"),
                                                withIntermediateDirectories: true)
        return root
    }

    /// pid ファイルが死んだプロセスを指し、ポートに誰も居ない → 数秒で「exited」と名指しして落ちる
    /// (v105 までは 180 秒待った末に「connection refused」だけだった)
    func testDeadRunnerFailsFastWithTheLastLogLine() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = BridgeLauncher(repoRoot: root, device: "iPhone 17", port: 8931, physical: false)
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try dead.run(); dead.waitUntilExit()
        try String(dead.processIdentifier).write(to: root.appendingPathComponent(".fleetest/bridge-8931.pid"),
                                                 atomically: true, encoding: .utf8)
        try "Command line invocation:\nxcodebuild: error: Existing file at -resultBundlePath\n"
            .write(to: root.appendingPathComponent(".fleetest/bridge-8931.log"), atomically: true, encoding: .utf8)
        let started = Date()
        do {
            try await launcher.waitUntilReady(timeout: 30)
            XCTFail("誰も listen していないポートで ready になるはずがない")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(text.contains("exited before the bridge became ready"), text)
            XCTAssertTrue(text.contains("Existing file at -resultBundlePath"), text)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "締切(30 秒)を待たずに落ちること")
    }

    /// 対照: 生きているプロセスを指していれば fail-fast しない(締切まで待って総称の理由で落ちる)
    func testAliveRunnerIsNotMistakenForADeadOne() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = BridgeLauncher(repoRoot: root, device: "iPhone 17", port: 8932, physical: false)
        let alive = Process()
        alive.executableURL = URL(fileURLWithPath: "/bin/sleep")
        alive.arguments = ["60"]
        try alive.run()
        defer { alive.terminate() }
        try String(alive.processIdentifier).write(to: root.appendingPathComponent(".fleetest/bridge-8932.pid"),
                                                  atomically: true, encoding: .utf8)
        try "Command line invocation:\n".write(to: root.appendingPathComponent(".fleetest/bridge-8932.log"),
                                                atomically: true, encoding: .utf8)
        do {
            try await launcher.waitUntilReady(timeout: 3)
            XCTFail("誰も listen していないポートで ready になるはずがない")
        } catch {
            let text = "\(error)"
            XCTAssertFalse(text.contains("exited before"), text)
        }
    }
}
