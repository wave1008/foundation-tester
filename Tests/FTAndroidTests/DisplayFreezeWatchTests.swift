import XCTest
import FTCore
@testable import FTAndroid

/// 境目の表示の確認の状態機械(撮影・nudge・回復は偽物)。実デバイスは触らない
final class DisplayFreezeWatchTests: XCTestCase {

    private final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var frames: [Data] = []
        var nudges = 0
        var nudgeLands = true
        var restores: [String?] = []
        var repairs = 0
        var logs: [String] = []
        var repairResult: WorkerRecoveryKind? = .deviceRestart
        /// 回復の後に撮れる絵(nil = 回復後も同じ絵)
        var frameAfterRepair: Data?
        var now: TimeInterval = 1000

        func sync<T>(_ body: () -> T) -> T { lock.withLock(body) }

        func nextFrame() -> Data? {
            sync {
                guard !frames.isEmpty else { return nil }
                return frames.removeFirst()
            }
        }
    }

    private func worker(platform: String = "android", physical: Bool = false) -> RunWorker {
        let connection = DriverConnection(
            platform: platform, port: nil,
            serial: platform == "android" ? "emulator-5554" : nil,
            udid: platform == "ios" ? "UDID-1" : nil, physical: physical)
        return RunWorker(label: "lane", platform: platform, driver: StubDriver(), connection: connection, logicalName: "dev")
    }

    private func makeWatch(_ probe: Probe) -> DisplayFreezeWatch {
        DisplayFreezeWatch(
            capture: { _ in probe.nextFrame() },
            nudge: { _ in probe.sync { probe.nudges += 1; return probe.nudgeLands } },
            restore: { _, appID in probe.sync { probe.restores.append(appID) } },
            repair: { _, stillFrozen, log in
                let result = probe.sync { probe.repairs += 1; return probe.repairResult }
                let frozen = await stillFrozen()
                log("repair ran; still frozen: \(frozen)")
                return result
            },
            now: { probe.sync { probe.now } })
    }

    private let frameA = Data("A".utf8)
    private let frameB = Data("B".utf8)

    func testFirstSampleIsHealthyAndNothingIsNudged() async {
        let probe = Probe(); probe.frames = [frameA]
        let outcome = await makeWatch(probe).check(worker(), restoring: "app") { _ in }
        XCTAssertEqual(outcome, .healthy)
        XCTAssertEqual(probe.nudges, 0)
    }

    func testSameFrameWithinAMinuteIsHealthy() async {
        let probe = Probe(); probe.frames = [frameA, frameA]
        let watch = makeWatch(probe)
        _ = await watch.check(worker(), restoring: "app") { _ in }
        probe.now += DisplayFreezeDetector.minSpanSeconds - 1
        let outcome = await watch.check(worker(), restoring: "app") { _ in }
        XCTAssertEqual(outcome, .healthy)
        XCTAssertEqual(probe.nudges, 0)
    }

    /// 60 秒より短いシナリオが続いても、同じ絵が最初に見えた時刻から数えて疑う(境目ごとに基準を上書きしない)
    func testTheSpanAccumulatesAcrossShortScenariosShowingTheSameFrame() async {
        let probe = Probe(); probe.frames = [frameA, frameA, frameA, frameB]
        let watch = makeWatch(probe)
        _ = await watch.check(worker(), restoring: "app") { _ in }
        probe.now += 40
        let second = await watch.check(worker(), restoring: "app") { _ in }
        XCTAssertEqual(second, .healthy)
        XCTAssertEqual(probe.nudges, 0)
        probe.now += 40  // 最初の絵から 80 秒
        let third = await watch.check(worker(), restoring: "app") { _ in }
        XCTAssertEqual(third, .healthy)  // nudge で別の絵 = 健全
        XCTAssertEqual(probe.nudges, 1)
    }

    /// **基準は run をまたぐ**: 1 つの run で境目を 1 回しか迎えないレーンでも、前の run の控えと比べて疑う
    /// (run ごとの控えだけだと、凍結した Emulator を一度も疑えなかった = 負荷テストで実測)
    func testBaselineCarriesOverToTheNextRunsWatch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dfw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = Probe(); probe.frames = [frameA] + Array(repeating: frameA, count: 40)
        func watch() -> DisplayFreezeWatch {
            DisplayFreezeWatch(
                capture: { _ in probe.nextFrame() },
                nudge: { _ in probe.sync { probe.nudges += 1; return true } },
                restore: { _, _ in },
                repair: { _, _, _ in probe.sync { probe.repairs += 1 }; return .deviceRestart },
                baseline: .files(in: dir),
                now: { probe.sync { probe.now } })
        }
        let first = await watch().check(worker(), restoring: "app") { _ in }
        XCTAssertEqual(first, .healthy)
        probe.now += DisplayFreezeDetector.minSpanSeconds
        let next = await watch().check(worker(), restoring: "app") { _ in }  // 別の run = 別のインスタンス
        guard case .frozen = next else { return XCTFail("前の run の基準と比べて疑うはず: \(next)") }
        XCTAssertEqual(probe.repairs, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("emulator-5554.json").path),
                       "回復の後は基準を捨てる")
    }

    /// 確認の入力を撃てなかったら判定しない(時計の無い静止画面の健全なデバイスを再起動しない)・SUT にも触らない
    func testUnissuedNudgeIsNotJudgedAndNothingIsRepaired() async {
        let probe = Probe(); probe.frames = [frameA] + Array(repeating: frameA, count: 40)
        probe.nudgeLands = false
        let watch = makeWatch(probe)
        _ = await watch.check(worker(), restoring: "app") { _ in }
        probe.now += DisplayFreezeDetector.minSpanSeconds
        let outcome = await watch.check(worker(), restoring: "app") { probe.logs.append($0) }
        XCTAssertEqual(outcome, .notChecked)
        XCTAssertEqual(probe.repairs, 0)
        XCTAssertEqual(probe.restores.count, 0)
        XCTAssertTrue(probe.logs.contains { $0.contains("could not press home") }, "\(probe.logs)")
    }

    func testSuspectThatChangesAfterTheNudgeIsHealthyAndNotRepaired() async {
        let probe = Probe(); probe.frames = [frameA, frameA, frameB]  // 2 枚目が疑い・nudge 後の 3 枚目は別の絵
        let watch = makeWatch(probe)
        _ = await watch.check(worker(), restoring: "app") { _ in }
        probe.now += DisplayFreezeDetector.minSpanSeconds
        let outcome = await watch.check(worker(), restoring: "app") { probe.logs.append($0) }
        XCTAssertEqual(outcome, .healthy)
        XCTAssertEqual(probe.nudges, 1)
        XCTAssertEqual(probe.repairs, 0)
        XCTAssertEqual(probe.restores, ["app"], "確認で背面に回した SUT を前面へ戻す")
        XCTAssertTrue(probe.logs.contains { $0.contains("not frozen") }, "\(probe.logs)")
    }

    func testSuspectThatStaysTheSameAfterTheNudgeIsFrozenAndRepaired() async {
        let probe = Probe()
        // 2 枚目が疑い・nudge 後の撮り直しは上限まで同じ絵(十分な枚数を用意)・回復後の確認も同じ絵
        probe.frames = [frameA] + Array(repeating: frameA, count: 40)
        let watch = makeWatch(probe)
        _ = await watch.check(worker(), restoring: "app") { _ in }
        probe.now += DisplayFreezeDetector.minSpanSeconds
        let outcome = await watch.check(worker(), restoring: "app") { probe.logs.append($0) }
        guard case .frozen(let detail, let recovery) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(recovery, .deviceRestart)
        XCTAssertTrue(detail.contains("did not change after a home press"), detail)
        XCTAssertEqual(probe.nudges, 1)
        XCTAssertEqual(probe.repairs, 1)
        XCTAssertEqual(probe.restores.count, 0, "凍結の確定後は戻さない(回復が起動し直す)")
        XCTAssertTrue(probe.logs.contains { $0.contains("still frozen: true") }, "\(probe.logs)")
    }

    func testRepairIsToldWhenTheFrameChangedAfterSleepWake() async {
        let probe = Probe()
        // 疑い → nudge 後も同じ(上限ぶん)→ 回復の確認で別の絵
        probe.frames = [frameA] + Array(repeating: frameA, count: 12) + [frameB]
        probe.repairResult = .displaySleepWake
        let watch = makeWatch(probe)
        _ = await watch.check(worker(), restoring: "app") { _ in }
        probe.now += DisplayFreezeDetector.minSpanSeconds
        let outcome = await watch.check(worker(), restoring: "app") { probe.logs.append($0) }
        guard case .frozen(_, let recovery) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(recovery, .displaySleepWake)
        XCTAssertTrue(probe.logs.contains { $0.contains("still frozen: false") }, "\(probe.logs)")
    }

    func testAfterARepairTheNextSampleStartsANewBaseline() async {
        let probe = Probe()
        probe.frames = [frameA] + Array(repeating: frameA, count: 40)
        let watch = makeWatch(probe)
        _ = await watch.check(worker(), restoring: "app") { _ in }
        probe.now += DisplayFreezeDetector.minSpanSeconds
        _ = await watch.check(worker(), restoring: "app") { _ in }
        // 回復の後、同じ絵が返っても(ブリッジの最初の絵)基準が無いので疑わない
        probe.frames = [frameA]
        probe.now += DisplayFreezeDetector.minSpanSeconds
        let outcome = await watch.check(worker(), restoring: "app") { _ in }
        XCTAssertEqual(outcome, .healthy)
        XCTAssertEqual(probe.nudges, 1)
    }

    func testPhysicalDevicesAreNotChecked() async {
        let probe = Probe(); probe.frames = [frameA]
        let outcome = await makeWatch(probe).check(worker(physical: true), restoring: "app") { _ in }
        XCTAssertEqual(outcome, .notChecked)
        XCTAssertEqual(probe.frames.count, 1, "実機は撮らない")
    }

    func testUnavailableCaptureIsNotCheckedAndKeepsTheBaseline() async {
        let probe = Probe(); probe.frames = [frameA]
        let watch = makeWatch(probe)
        _ = await watch.check(worker(), restoring: "app") { _ in }
        probe.now += DisplayFreezeDetector.minSpanSeconds
        let unavailable = await watch.check(worker(), restoring: "app") { _ in }
        XCTAssertEqual(unavailable, .notChecked)  // 撮れない
        // 基準は残る: 次に同じ絵が返れば疑いになる
        probe.frames = [frameA, frameB]
        probe.now += 1
        let later = await watch.check(worker(), restoring: "app") { _ in }
        XCTAssertEqual(later, .healthy)
        XCTAssertEqual(probe.nudges, 1)
    }

    func testInjectedKeyReturnsTheFixedFrame() async {
        let frame = await DisplayFreezeWatch.productionCapture(worker(), injected: ["emulator-5554"])
        XCTAssertEqual(frame, DisplayFreezeWatch.injectedFrame)
    }

    /// 境目の待ちの上限と刻みをリテラルで固定する(ランチャーの描画は負荷の高い Emulator でも 1〜2 秒の実測)
    func testBudgetsArePinned() {
        XCTAssertEqual(DisplayFreezeWatch.captureBudgetSeconds, 10)
        XCTAssertEqual(DisplayFreezeWatch.nudgeChangeWaitSeconds, 3)
        XCTAssertEqual(DisplayFreezeWatch.nudgeChangePollSeconds, 0.3)
    }
}

/// 撮影・home を呼ばれない前提のドライバ(テストは閉包で差し替える。呼ばれたら 501)
private struct StubDriver: AppDriver {
    func status() async throws -> StatusResponse { throw DriverError.badResponse(status: 501, body: "stub") }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func snapshot() async throws -> SnapshotResponse { throw DriverError.badResponse(status: 501, body: "stub") }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { throw DriverError.badResponse(status: 501, body: "stub") }
    func terminate() async throws {}
}
