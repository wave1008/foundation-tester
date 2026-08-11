// **陽性対照**: 凍結を注入したとき、run 前トリアージが公表し、モニターがそれを凍結として出す。
//
// この経路が一度も通っていなかったのが 2026-08-11 の欠陥で、当時の検証(実デバイスで10台に
// frozen が乗り誤検知 0)は**恒久 false を返す検出器が出す観測と同一**だった。
// 凍結は意図的に起こせないので、注入(`FrozenInjection`)を唯一の陽性側の入口として常設する。
//
// 注入は**観測と配信の経路だけ**を通す: 実体は健全なので回復(simctl shutdown/boot)も除外も
// 撃たない。これを守らないと、対照実験のたびにフリートが再起動する。

import XCTest
@testable import ftester
@testable import FTCore

/// スクショは常に空 = 一様判定は false(注入だけが根拠になることを保証する)
private struct HealthyDriver: AppDriver {
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                         elements: [], truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class FrozenPositiveControlTests: XCTestCase {
    private var stateDir: URL!
    private let udid = "positive-control-udid"

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-positive-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func worker() -> RunWorker {
        RunWorker(label: "sim(ios:8123)", platform: "ios", driver: HealthyDriver(),
                  connection: DriverConnection(platform: "ios", udid: udid, physical: false),
                  logicalName: "sim")
    }

    /// 注入 → トリアージが公表 → **モニターが凍結と言う**。落ちたら検知の配線が切れている
    func testInjectionTravelsFromTriageToMonitor() async throws {
        let environment = [FrozenInjection.environmentKey: udid]
        let result = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker()], stateDir: stateDir, environment: environment, log: { _ in })

        XCTAssertEqual(result.excluded, [], "注入は実体が健全なので除外しない")
        XCTAssertEqual(result.workers.count, 1)

        XCTAssertEqual(DeviceFrozenStore.current(stateDir: stateDir, key: udid)?.evidence,
                       [.injected], "トリアージが公表していない")

        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile", key: udid, debounce: MonitorFrozenDebounce(confirmThreshold: 2),
            stateDir: stateDir, environment: [:])
        XCTAssertTrue(verdict.isFrozen, "run が公表した凍結がモニターに出ていない")
    }

    /// **注入では回復を撃たない**(実デバイスを再起動しない)
    func testInjectionDoesNotTriggerRecovery() async throws {
        let recovered = RecordingBox()
        _ = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker()],
            recover: { @Sendable labels in
                recovered.record(labels)
                return nil
            },
            stateDir: stateDir,
            environment: [FrozenInjection.environmentKey: udid],
            log: { _ in })
        XCTAssertTrue(recovered.calls.isEmpty,
                      "注入は観測経路を通すためのもの。simctl shutdown/boot を撃ってはいけない")
    }

    /// 注入を外すと公表が消え、モニターの表示も戻る(解除まで含めて1周)
    func testRemovingInjectionClearsThePublication() async throws {
        _ = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker()], stateDir: stateDir,
            environment: [FrozenInjection.environmentKey: udid], log: { _ in })
        XCTAssertNotNil(DeviceFrozenStore.current(stateDir: stateDir, key: udid))

        _ = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker()], stateDir: stateDir, environment: [:], log: { _ in })
        XCTAssertNil(DeviceFrozenStore.current(stateDir: stateDir, key: udid),
                     "回復したら公表が消える(syncStore が自分の分を消してから書き直す)")

        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile", key: udid, debounce: MonitorFrozenDebounce(confirmThreshold: 2),
            stateDir: stateDir, environment: [:])
        XCTAssertFalse(verdict.isFrozen)
    }

    /// 注入が無ければ何も公表しない(この対照が常時 true を返していないことの確認)
    func testHealthyFleetPublishesNothing() async throws {
        _ = await BlankWorkerTriage.excludeBlankScreenWorkers(
            [worker()], stateDir: stateDir, environment: [:], log: { _ in })
        XCTAssertNil(DeviceFrozenStore.current(stateDir: stateDir, key: udid))
    }
}

/// recover が呼ばれたかを記録する箱(@Sendable クロージャから書くため)
private final class RecordingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []
    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func record(_ labels: [String]) {
        lock.lock(); storage.append(labels); lock.unlock()
    }
}
