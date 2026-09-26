// 録画セッションが残った iOS シミュレータの再起動(ProfileWorkerFactory.recoverStaleRecordingIOSWorkers)。
// 検査(simctl)と再起動は注入口で差し替え、「どの台を・いつ再起動し・何を返すか」だけを見る。

import XCTest
@testable import FTCore
@testable import FTAndroid

private struct StubDriver: AppDriver {
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

/// 検査と再起動の呼ばれ方の記録
private actor Calls {
    var probed: [String] = []
    var recovered: [[String]] = []
    var logs: [String] = []
    func probe(_ udid: String) { probed.append(udid) }
    func recover(_ labels: [String]) { recovered.append(labels) }
    func log(_ line: String) { logs.append(line) }
}

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class StaleRecordingRecoveryTests: XCTestCase {

    private func profile(record: Bool) -> ResolvedProfile {
        ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "run", appName: "app", apps: [:], devices: [],
            fm: FMConfig(), heal: false,
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosFastInput: false, iosPreActionWarmup: true, containerInference: true,
            ocrTextOcclusionCheck: true, preferCheckStateClassifier: true, enableAnimations: false,
            homeOnStart: true, playProtectBypass: true, record: record, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
    }

    private func sim(_ label: String, port: UInt16 = 8123) -> RunWorker {
        RunWorker(label: label, platform: "ios", driver: StubDriver(),
                  connection: DriverConnection(platform: "ios", port: port, udid: "UDID-\(label)"))
    }

    private let repo = URL(fileURLWithPath: "/tmp/dummy-repo")

    /// 録画しない run では検査そのものを撃たない(検査は録画の開始・停止なので)
    func testNothingHappensWhenTheRunDoesNotRecord() async {
        let calls = Calls()
        let workers = [sim("a")]
        let result = await ProfileWorkerFactory.recoverStaleRecordingIOSWorkers(
            workers: workers, resolved: profile(record: false), repoRoot: repo, apps: [:],
            probe: { await calls.probe($0); return .busy },
            recover: { labels, current in await calls.recover(labels); return current },
            log: { _ in })
        let probed = await calls.probed
        let recovered = await calls.recovered
        XCTAssertEqual(probed, [])
        XCTAssertEqual(recovered, [])
        XCTAssertEqual(result.map(\.label), ["a"])
    }

    /// busy の台だけを再起動し、再起動後の一覧を返す(再起動した台は検査し直す)
    func testOnlyBusySimulatorsAreRebootedAndTheRebuiltListIsReturned() async {
        let calls = Calls()
        let sink = LogSink()
        let workers = [sim("a"), sim("b"), sim("c")]
        let rebuiltList = [sim("a", port: 9001), sim("b", port: 9002), sim("c", port: 9003)]
        let result = await ProfileWorkerFactory.recoverStaleRecordingIOSWorkers(
            workers: workers, resolved: profile(record: true), repoRoot: repo, apps: [:],
            probe: { udid in
                await calls.probe(udid)
                let recoveredYet = await !calls.recovered.isEmpty
                return udid == "UDID-b" && !recoveredYet ? .busy : .free
            },
            recover: { labels, _ in await calls.recover(labels); return rebuiltList },
            log: { sink.add($0) })
        let recovered = await calls.recovered
        let probed = await calls.probed
        XCTAssertEqual(recovered, [["b"]], "busy の台だけを渡す")
        XCTAssertEqual(probed.filter { $0 == "UDID-b" }.count, 2, "再起動した台は検査し直す")
        XCTAssertEqual(result.map(\.connection.port), [9001, 9002, 9003], "張り直した一覧を返す")
        XCTAssertTrue(sink.all.contains { $0.contains("recording every simulator") }, sink.all.joined(separator: "\n"))
    }

    /// 実機と Android は検査しない(実機は録れない / Android は別の録画方式)。udid を持たせて確かめる
    func testPhysicalAndAndroidAreNeverProbed() async {
        let calls = Calls()
        let physical = RunWorker(label: "p", platform: "ios", driver: StubDriver(),
                                 connection: DriverConnection(platform: "ios", port: 8123,
                                                              udid: "UDID-p", physical: true))
        let android = RunWorker(label: "d", platform: "android", driver: StubDriver(),
                                connection: DriverConnection(platform: "android", port: 8200,
                                                             serial: "emulator-d", udid: "UDID-d"))
        _ = await ProfileWorkerFactory.recoverStaleRecordingIOSWorkers(
            workers: [physical, android, sim("a")], resolved: profile(record: true), repoRoot: repo, apps: [:],
            probe: { await calls.probe($0); return .busy },
            recover: { labels, current in await calls.recover(labels); return current },
            log: { _ in })
        let probed = await calls.probed
        let recovered = await calls.recovered
        XCTAssertEqual(Set(probed), ["UDID-a"])
        XCTAssertEqual(recovered.first, ["a"])
    }

    /// 検査が言えなかった台(unknown)は再起動しない
    func testUnknownIsNotRebooted() async {
        let calls = Calls()
        let result = await ProfileWorkerFactory.recoverStaleRecordingIOSWorkers(
            workers: [sim("a")], resolved: profile(record: true), repoRoot: repo, apps: [:],
            probe: { await calls.probe($0); return .unknown },
            recover: { labels, current in await calls.recover(labels); return current },
            log: { _ in })
        let recovered = await calls.recovered
        XCTAssertEqual(recovered, [])
        XCTAssertEqual(result.map(\.label), ["a"])
    }

    /// 再起動できなくても、解けなくても、台は外さない(録画だけが欠ける)
    func testWorkersAreNeverDroppedWhenRecoveryFailsOrDoesNotHelp() async {
        let sink = LogSink()
        let failed = await ProfileWorkerFactory.recoverStaleRecordingIOSWorkers(
            workers: [sim("a"), sim("b")], resolved: profile(record: true), repoRoot: repo, apps: [:],
            probe: { _ in .busy },
            recover: { _, _ in nil },
            log: { sink.add($0) })
        XCTAssertEqual(failed.map(\.label), ["a", "b"], "再起動できなければ元の一覧のまま")
        XCTAssertTrue(sink.all.contains { $0.contains("could not reboot") })

        let stuck = await ProfileWorkerFactory.recoverStaleRecordingIOSWorkers(
            workers: [sim("a")], resolved: profile(record: true), repoRoot: repo, apps: [:],
            probe: { _ in .busy },
            recover: { _, current in current },
            log: { sink.add($0) })
        XCTAssertEqual(stuck.map(\.label), ["a"], "解けなくても外さない")
        XCTAssertTrue(sink.all.contains { $0.contains("still held after a reboot") })
    }
}
