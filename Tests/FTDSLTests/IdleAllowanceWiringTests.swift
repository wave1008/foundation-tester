// 長さの決まった無出力の待ち(canSelect 系・httpRequest・doUntilTrue)が子→親へ `idleAllowance` を申告すること。
// 申告が無いと、親の idle 打ち切り(2 × commandTimeout の無出力で止める)が正常に待っている子を止める。

import XCTest
@testable import FTDSL
import FTCore

final class IdleAllowanceWiringTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var events: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private final class NullDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
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
    }

    private let sink = Sink()

    private func runWithCore(_ body: () -> Void) {
        let core = FTDriveCore(driver: NullDriver(), platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(),
                               visionClassifierProjectRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                               dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-idle-allowance-test.json"),
                               emit: { [sink] in sink.add($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        body()
    }

    /// began の上限(ms)と ended が対で出ること
    private func allowances() -> [String] {
        sink.events.filter { $0.kind == "idleAllowance" }
            .map { "\($0.status ?? "-"):\($0.durationMs.map(String.init) ?? "-")" }
    }

    func testIfCanSelectDeclaresItsWait() {
        runWithCore { ifCanSelect("#definitely_missing", waitSeconds: 0.3) {} }
        XCTAssertEqual(allowances(), ["began:300", "ended:-"])
    }

    func testIfCanSelectWithoutWaitDeclaresNothing() {
        runWithCore { ifCanSelect("#definitely_missing") {} }
        XCTAssertEqual(allowances(), [])
    }

    func testDoUntilTrueDeclaresWaitPlusOneInterval() {
        runWithCore { doUntilTrue("never", waitSeconds: 0.2, intervalSeconds: 0.05) { false } }
        XCTAssertEqual(allowances(), ["began:250", "ended:-"])
    }

    /// 送り先は接続を即座に断られる番号(1 番)—— 応答の成否に関わらず待ちの前後で申告する
    func testHTTPRequestDeclaresTimeoutPlusTheSemaphoreMargin() {
        runWithCore { _ = httpRequest("http://127.0.0.1:1/", waitSeconds: 5) }
        XCTAssertEqual(allowances(), ["began:6000", "ended:-"])
    }
}
