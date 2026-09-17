// FTRuntime.perform の failureKind 決定(M14): outcome が nil(FTSync が打ち切った)のときだけ
// .timeout で埋める。outcome があるのに StepExecutor が failureKind を名乗らなかった失敗まで
// .timeout に丸めない —— 2026-09 の結果DBで failureKind=timeout 41 件中 7 件が誤りだった
// (clearInput の値残りのように、何もタイムアウトしていない失敗)。

import XCTest
@testable import FTDSL
import FTCore

final class FTRuntimeFailureKindTests: XCTestCase {

    /// clearInput が「成功」を返しても値が残っていた形(performClearInput の事後検証)を再現する
    /// ドライバ。clearInput(ref:) は何もしない = 常に値が残ったままなので、必ずこの失敗を踏む
    private final class StuckClearInputDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func clearAppData(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "textField", identifier: "field", label: nil,
                                       value: "leftover", placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        // 「成功」を返すが実際には何も消していない = 事後検証(残存値の比較)が必ず引っかかる
        func clearInput(ref: Int?) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    /// outcome が非 nil(StepExecutor が最後まで走った)なのに failureKind を名乗らなかった失敗は、
    /// 記録される ScenarioEvent.failureKind も nil のままであること(.timeout に丸めない)
    func testFailureWithoutFailureKindIsNotRecordedAsTimeout() {
        var events: [ScenarioEvent] = []
        let core = FTDriveCore(driver: StuckClearInputDriver(), platform: "ios",
                               app: "com.example.app", scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-heal-test-failurekind.json"),
                               emit: { events.append($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { clearInput("#field") }
            }
        }

        let stepEvents = events.filter { $0.kind == "step" }
        guard let failed = stepEvents.first(where: { $0.status == "failed" }) else {
            return XCTFail("clearInput が失敗として記録されていない: \(stepEvents)")
        }
        XCTAssertEqual(failed.detail, "clearInput reported success but the value remained: \"leftover\"")
        XCTAssertNil(failed.failureKind,
                     "StepExecutor が素性を名乗らなかった失敗を .timeout に丸めてはいけない")
    }
}
