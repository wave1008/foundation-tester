// buildAndroidWorkers の部分失敗許容を、注入した makeWorker の継ぎ目を通して検証する。
// 実デバイス無しで規則(FleetOutcome.resolve)が正しく配線されているかだけを見る
// (規則そのものの網羅は FTCoreTests/FleetOutcomeTests。ここは配線の確認)。
//
// 2026-08-16 の実害: エミュレータ2台が別プロファイル実行中に死に、`try ... map` が丸ごと throw
// して後続3プロファイル74本が開始前に全滅した。健全な6台は使われなかった。

import XCTest
@testable import FTCore
import FTAndroid

private struct ProbeError: Error, LocalizedError {
    let label: String
    var errorDescription: String? { label }
}

/// AppDriver の最小スタブ(デフォルト実装の無い要件だけ埋める。BlankWorkerTriageTests の
/// UnusedDriver と同じ最小集合)
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

final class BuildAndroidWorkersPartialFailureTests: XCTestCase {

    /// **avd を与えない**(ホストの adb を叩かないため)。`buildAndroidWorkers` は入口で
    /// `syncAnimationSettings` を通り、avd があると起動中エミュレータの照合で1台につき
    /// `adb` を数回起動する。ここで見たいのは集約規則の配線だけで、解決は `makeWorker` の
    /// スタブが担うので spec の中身は要らない
    private func androidDevices(_ count: Int) -> [ResolvedDevice] {
        (1...count).map { ResolvedDevice(platform: "android", spec: DeviceSpec(name: "d\($0)")) }
    }

    /// `ResolvedProfile` の memberwise init は internal なので `@testable import FTCore` で触る
    /// (AndroidFrozenPublicationTests.swift と同じ手段)
    private func profile(devices: [ResolvedDevice]) -> ResolvedProfile {
        ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "run",
            machineName: "machine",
            appName: "app",
            apps: [:],
            devices: devices,
            fm: FMConfig(),
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: nil,
            scenarioTimeout: nil,
            wipeDataOnBloat: true,
            updateWebView: false,
            wipeDataThresholdGB: 8,
            recoverCpuFallbackToGpu: false,
            locale: "ja_JP",
            iosFastInput: false,
            iosPreActionWarmup: true,
            containerInference: true,
            enableAnimations: false,
            homeOnStart: true,
            record: false,
            recordFailuresOnly: false,
            recordBitrateKbps: 1500,
            recordFullResolution: false,
            warnings: [])
    }

    private func worker(for device: ResolvedDevice) -> RunWorker {
        RunWorker(label: RunWorker.makeLabel(deviceName: device.name, platform: "android", id: device.name),
                  platform: "android", driver: StubDriver(),
                  connection: DriverConnection(platform: "android", serial: device.name,
                                               deviceName: device.name, physical: false),
                  logicalName: device.name)
    }

    /// **本丸**: 8台中2台の解決失敗でも、6台ぶんのワーカーが返る(2026-08-16 の比率そのもの)。
    /// `buildAndroidWorkers` の実装を `try resolved.androidDevices.map { ... }` へ戻す変異が入ると、
    /// 1台目の失敗(d2)で丸ごと throw するようになりこのテストは必ず落ちる
    func testTwoOfEightFailuresStillReturnSixWorkers() throws {
        let devices = androidDevices(8)
        let failing: Set<String> = ["d2", "d7"]
        var loggedLines: [String] = []
        let workers = try ProfileWorkerFactory.buildAndroidWorkers(
            resolved: profile(devices: devices),
            log: { loggedLines.append($0) },
            makeWorker: { device in
                if failing.contains(device.name) {
                    throw ProbeError(label: "\(device.name) failed")
                }
                return self.worker(for: device)
            })
        XCTAssertEqual(workers.count, 6, "健全な6台を道連れにしてはいけない")
        XCTAssertEqual(Set(workers.compactMap(\.logicalName)),
                       Set(devices.map(\.name)).subtracting(failing))
        XCTAssertTrue(loggedLines.contains { $0.contains("❌ d2:") })
        XCTAssertTrue(loggedLines.contains { $0.contains("❌ d7:") })
        XCTAssertTrue(loggedLines.contains { $0.contains("2 device(s) could not be resolved")
            && $0.contains("continuing with 6 device(s)") })
    }

    /// 全滅のときは throw する(呼び出し側が run の失敗として扱えるように現状維持)
    func testAllFailuresThrow() {
        let devices = androidDevices(3)
        XCTAssertThrowsError(
            try ProfileWorkerFactory.buildAndroidWorkers(
                resolved: profile(devices: devices),
                log: { _ in },
                makeWorker: { device in throw ProbeError(label: "\(device.name) failed") })
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.label, "d1 failed", "デバイス順で最初のエラーを投げる")
        }
    }

    /// 全員成功なら失敗ログは出ない
    func testAllSucceedProducesNoFailureLog() throws {
        let devices = androidDevices(3)
        var loggedLines: [String] = []
        let workers = try ProfileWorkerFactory.buildAndroidWorkers(
            resolved: profile(devices: devices),
            log: { loggedLines.append($0) },
            makeWorker: { device in self.worker(for: device) })
        XCTAssertEqual(workers.count, 3)
        XCTAssertFalse(loggedLines.contains { $0.contains("could not be resolved") })
    }
}
