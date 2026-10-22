// appSwitcher(): ホームボタンの iPhone(画面の寸法で判定)では撃たず、シナリオを対象外(skipped)で記録する。
// 失敗にしない・以降の手順は skipped・iOS 以外は従来どおり撃つ。

import XCTest
@testable import FTDSL
@testable import FTCore

final class AppSwitcherHomeButtonSkipTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var steps: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == "step" } }
    }

    private final class ScreenDriver: AppDriver {
        let width: Double
        let height: Double
        private let switcherCount = LockedValue(0)
        private let tapCount = LockedValue(0)
        init(width: Double, height: Double) { self.width = width; self.height = height }
        var switcherCalls: Int { switcherCount.value }
        var taps: Int { tapCount.value }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func openAppSwitcher() async throws { switcherCount.withLock { $0 += 1 } }
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: width, height: height),
                elements: [ElementInfo(ref: 1, type: "button", identifier: "counter", label: "count",
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 10, y: 20, width: 50, height: 40), depth: 1)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tapCount.withLock { $0 += 1 } }
        func tap(x: Double, y: Double) async throws { tapCount.withLock { $0 += 1 } }
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private let sink = Sink()
    private var dir: URL!
    private let reason = "appSwitcher is not available on a home-button iPhone"
        + " (the switcher is a hardware double-press XCUITest cannot send)"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-switcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func run(platform: String, driver: ScreenDriver) -> FTDriveCore {
        let core = FTDriveCore(driver: driver, platform: platform, app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(),
                               visionClassifierProjectRoot: dir, dryRun: false,
                               fingerprintCacheURL: dir.appendingPathComponent("fp.json"),
                               emit: { [sink] in sink.add($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario {
            scene(1, "s") {
                action {
                    appSwitcher()
                    tap("#counter", settle: false)
                }
            }
        }
        return core
    }

    func testHomeButtonIPhoneIsRecordedAsSkippedNotFailed() throws {
        let driver = ScreenDriver(width: 375, height: 667)
        let core = run(platform: "ios", driver: driver)
        XCTAssertEqual(driver.switcherCalls, 0, "ブリッジの 422 に当てない")
        XCTAssertEqual(driver.taps, 0, "以降の手順は実行しない")
        XCTAssertTrue(core.finalRecord.passed, "対象外は失敗ではない")
        XCTAssertEqual(core.notApplicableReason, reason)
        let steps = sink.steps
        XCTAssertEqual(steps.map(\.status), ["skipped", "skipped"])
        XCTAssertEqual(steps.first?.detail, reason)
        XCTAssertEqual(steps.first?.command, "appSwitcher")
    }

    func testFaceIDIPhoneStillCallsTheDriver() {
        let driver = ScreenDriver(width: 393, height: 852)
        let core = run(platform: "ios", driver: driver)
        XCTAssertEqual(driver.switcherCalls, 1)
        XCTAssertNil(core.notApplicableReason)
        XCTAssertEqual(driver.taps, 1)
    }

    func testAndroidIsUnaffectedEvenWithAHomeButtonAspect() {
        let driver = ScreenDriver(width: 375, height: 667)
        let core = run(platform: "android", driver: driver)
        XCTAssertEqual(driver.switcherCalls, 1)
        XCTAssertNil(core.notApplicableReason)
    }
}
