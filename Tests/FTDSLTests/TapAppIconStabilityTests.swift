// tapAppIcon: 動いているランチャーを撃たない(枠が連続2枚で同じになってから撃つ)・対象アプリが
// 前面にならなければ事実の文言で失敗する・失敗しても撃ち直さない。

import XCTest
@testable import FTDSL
@testable import FTCore

final class TapAppIconStabilityTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var steps: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == "step" } }
    }

    /// n 回目(0 始まり)の snapshot が frames[min(n, last)] の位置に "FT E2E" を載せる。ref は 100 + n
    private final class LauncherDriver: AppDriver {
        let frames: [FTRect]
        let foreground: Bool
        private let snapshotCount = LockedValue(0)
        private let tappedRefs = LockedValue<[Int]>([])
        init(frames: [FTRect], foreground: Bool) { self.frames = frames; self.foreground = foreground }
        var taps: [Int] { tappedRefs.value }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { foreground }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func home() async throws {}
        func snapshot() async throws -> SnapshotResponse {
            let n = snapshotCount.withLock { value -> Int in defer { value += 1 }; return value }
            let frame = frames[min(n, frames.count - 1)]
            return SnapshotResponse(
                sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 100 + n, type: "button", identifier: nil, label: "FT E2E",
                                       value: nil, placeholder: nil, enabled: true, frame: frame, depth: 1)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tappedRefs.withLock { $0.append(ref) } }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private let sink = Sink()
    private var dir: URL!
    private let a = FTRect(x: 100, y: 200, width: 50, height: 40)
    private let b = FTRect(x: 100, y: 120, width: 50, height: 40)

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-tapicon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func run(_ driver: LauncherDriver) -> FTDriveCore {
        let core = FTDriveCore(driver: driver, platform: "android", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false,
                               tunables: RunTunables(screenWaitTimeout: 0.3),
                               visionClassifierProjectRoot: dir, dryRun: false,
                               fingerprintCacheURL: dir.appendingPathComponent("fp.json"),
                               emit: { [sink] in sink.add($0) })
        core.appDisplayName = "FT E2E"
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { tapAppIcon() } } }
        return core
    }

    func testTapsTheFrameThatStayedPutNotTheFirstOneRead() {
        let driver = LauncherDriver(frames: [a, b, b], foreground: true)
        _ = run(driver)
        XCTAssertEqual(driver.taps, [102], "1枚目(動いていた)の ref 100 ではなく、2枚連続で同じだった木の ref")
    }

    func testFailsWithTheFactWhenTheAppNeverComesToTheForegroundAndTapsOnce() {
        let driver = LauncherDriver(frames: [a], foreground: false)
        let core = run(driver)
        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertEqual(driver.taps.count, 1, "撃ち直さない")
        let detail = sink.steps.first { $0.status == "failed" }?.detail ?? ""
        XCTAssertTrue(detail.contains("tapAppIcon \"FT E2E\": tapped the icon at (125,220)"), detail)
        XCTAssertTrue(detail.contains("com.example.app did not come to the foreground within"), detail)
    }

    func testPassesWhenTheAppIsForeground() {
        let driver = LauncherDriver(frames: [a], foreground: true)
        let core = run(driver)
        XCTAssertTrue(core.finalRecord.passed, "\(sink.steps.map { "\($0.description ?? ""): \($0.detail ?? "")" })")
        XCTAssertEqual(driver.taps.count, 1)
    }
}
