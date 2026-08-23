// 登録の無いシステムアラートを**フェーズ(condition / action / expectation)の先頭の最初の触る操作**で
// 1回だけ確かめることの固定(FTRuntime.runSection → StepExecutor.armUnregisteredSystemAlertProbe)。
// 受け手報告 2026-08-22: 通知 → ATT の2枚はオンボーディングの途中(アプリ内の事前説明を閉じた直後)
// に出るので、launch 直後の1回では拾えない。フェーズ単位で見れば次の action の最初の操作で拾える。
// 常時監視にはしない(費用を払うのは登録がある間だけ、という 0ec9b245 の判断を崩さない)

import XCTest
import FTCore
@testable import FTDSL

final class UnregisteredSystemAlertPhaseTests: XCTestCase {

    /// 触ると何も起きない主ドライバ(要素 #a が常に居る)
    private final class PrimaryDriver: AppDriver {
        private(set) var taps = 0
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [ElementInfo(ref: 1, type: "button", identifier: "a", label: "A",
                                                    value: nil, placeholder: nil, enabled: true,
                                                    frame: FTRect(x: 10, y: 10, width: 100, height: 40),
                                                    depth: 0)],
                             truncatedCount: 0)
        }
        func tap(ref: Int) async throws { taps += 1 }
        func tap(x: Double, y: Double) async throws { taps += 1 }
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    /// SpringBoard 側(XCUITest フォールバック)。**常にアラートが前面**と答える
    private final class AlertingFallback: AppDriver {
        private(set) var probes = 0
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
        func systemAlert() async throws -> SystemAlertProbeResponse? {
            probes += 1
            return SystemAlertProbeResponse(present: true, title: "“App”は通知を送信します",
                                            buttons: ["許可しない", "許可"])
        }
    }

    func testEachPhaseProbesOnceOnItsFirstTouchAndNotEveryStep() {
        var events: [ScenarioEvent] = []
        let primary = PrimaryDriver()
        let fallback = AlertingFallback()
        let core = FTDriveCore(driver: primary, platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false,
                               falsePositiveCheckEnabled: false, dryRun: false,
                               healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-unregistered-alert-phase-test.json"),
                               fallbackDriver: fallback,
                               emit: { events.append($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                condition { tap("#a"); tap("#a") }
                    .action { tap("#a"); tap("#a") }
                    .expectation { exist("#a") }
            }
        }

        let steps = events.filter { $0.kind == "step" }
        let noted = steps.filter { $0.notes?.contains(StepNote.systemAlertPresent.rawValue) == true }
        // condition の最初の tap と action の最初の tap にだけ付く(expectation は触らないので無し)
        XCTAssertEqual(noted.map { $0.description ?? "" }.count, 2,
                       "各フェーズの最初の触る操作にだけ付くはず: \(steps.map { "\($0.description ?? "")=\($0.notes ?? [])" })")
        XCTAssertEqual(fallback.probes, 2, "フェーズごとに1回だけ聞く(毎ステップではない): \(fallback.probes)")
        XCTAssertEqual(primary.taps, 4, "注記は出すが操作は止めない")
    }
}
