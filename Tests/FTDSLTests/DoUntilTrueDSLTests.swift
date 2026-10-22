// doUntilTrue のブロックの中で DSL のコマンドを呼べること(Shirates の基本形 `{ scrollDown(); canSelect(...) }`)と、
// 周ごとの記録・中の失敗での中断・上限回数・throw・dry-run・減速の待ちの差し引き。

import XCTest
@testable import FTDSL
@testable import FTCore

final class DoUntilTrueDSLTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var steps: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == "step" } }
    }

    /// 木には `#counter` だけがある。タップの回数を数える
    private final class CountingDriver: AppDriver {
        private let taps = LockedValue(0)
        var tapCount: Int { taps.value }

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
                             elements: [ElementInfo(ref: 1, type: "button", identifier: "counter", label: "count",
                                                    value: nil, placeholder: nil, enabled: true,
                                                    frame: FTRect(x: 100, y: 200, width: 50, height: 40), depth: 1)],
                             truncatedCount: 0)
        }
        func tap(ref: Int) async throws { taps.withLock { $0 += 1 } }
        func tap(x: Double, y: Double) async throws { taps.withLock { $0 += 1 } }
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private let sink = Sink()
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-dountiltrue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func makeCore(driver: AppDriver, dryRun: Bool = false) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, tunables: RunTunables(),
                    visionClassifierProjectRoot: dir, dryRun: dryRun,
                    fingerprintCacheURL: dir.appendingPathComponent("fp.json"),
                    emit: { [sink] in sink.add($0) })
    }

    func testDSLCommandsRunInsideTheBlockAndEachAttemptIsAGroup() {
        let driver = CountingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    doUntilTrue("3 回押す", waitSeconds: 5, intervalSeconds: 0.01) {
                        tap("#counter", settle: false)
                        return driver.tapCount >= 3
                    }
                }
            }
        }

        XCTAssertTrue(core.finalRecord.passed, "\(sink.steps.map { "\($0.description ?? ""): \($0.status ?? "")" })")
        XCTAssertEqual(driver.tapCount, 3, "中の tap が実際に撃たれている")
        let descriptions = sink.steps.map { $0.description ?? "" }
        XCTAssertFalse(descriptions.contains { $0.hasPrefix("thread violation") }, "中の DSL がスレッド違反になっている")
        for attempt in 1...3 {
            XCTAssertTrue(descriptions.contains { $0.contains("[3 回押す #\(attempt)]") && $0.contains("tap") },
                          "\(attempt) 周目の tap が周のまとまりとして記録されていない: \(descriptions)")
        }
        XCTAssertEqual(descriptions.last, "doUntilTrue \"3 回押す\" → 3 attempt(s)")
    }

    func testAFailingCommandInsideStopsTheScenarioWithoutASecondFailure() {
        let core = makeCore(driver: CountingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var attempts = 0
        scenario {
            scene(1, "s") {
                action {
                    doUntilTrue("無い要素", waitSeconds: 5, intervalSeconds: 0.01) {
                        attempts += 1
                        tap("#missing", settle: false, waitSeconds: 0)
                        return false
                    }
                }
            }
        }

        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertEqual(attempts, 1, "中の失敗でシナリオが止まったら次の周を回さない")
        let failed = sink.steps.filter { $0.status == "failed" }
        XCTAssertEqual(failed.count, 1, "中の失敗だけが記録される: \(failed.map { $0.description ?? "" })")
        XCTAssertFalse(sink.steps.contains { ($0.description ?? "").hasPrefix("doUntilTrue") && $0.status == "failed" })
    }

    func testTheAttemptLimitAndAThrowBothFailTheStep() {
        let core = makeCore(driver: CountingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var attempts = 0
        scenario {
            scene(1, "s") {
                action {
                    doUntilTrue("成立しない", waitSeconds: 5, intervalSeconds: 0, maxLoopCount: 4) {
                        attempts += 1
                        return false
                    }
                }
            }
        }
        XCTAssertEqual(attempts, 4)
        XCTAssertTrue(sink.steps.last?.detail?.contains("4-attempt limit") == true, "\(String(describing: sink.steps.last))")

        let throwing = makeCore(driver: CountingDriver())
        FTRuntime.tearDown()
        FTRuntime.bootstrap(core: throwing, dslThread: Thread.current)
        var thrownAttempts = 0
        struct Boom: Error {}
        scenario {
            scene(1, "s") {
                action {
                    doUntilTrue("投げる", waitSeconds: 5, intervalSeconds: 0) {
                        thrownAttempts += 1
                        throw Boom()
                    }
                }
            }
        }
        XCTAssertEqual(thrownAttempts, 1, "throw はやり直さない")
        XCTAssertFalse(throwing.finalRecord.passed)
    }

    func testDryRunListsTheInnerStepsOnce() {
        let core = makeCore(driver: CountingDriver(), dryRun: true)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var attempts = 0
        scenario {
            scene(1, "s") {
                action {
                    doUntilTrue("列挙", waitSeconds: 5) {
                        attempts += 1
                        tap("#counter")
                        return false
                    }
                }
            }
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(sink.steps.contains { ($0.description ?? "").contains("[列挙 #1]") })
    }

    /// 中の操作の前でステップの減速が待った分は上限から差し引く。上限 0.3 秒・1周ごとに 200ms 待つ形で、
    /// 3周目に成立する(差し引かないと2周目の後で上限切れ)
    func testPacingInsideDoesNotEatTheBudget() {
        let driver = CountingDriver()
        let core = makeCore(driver: driver)
        core.hostLoadPacing = HostLoadPacingPlan(tiers: [.init(cpuPercentAtLeast: 95, delayMs: 200)])
        core.hostCPUNow = { 0.97 }
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    doUntilTrue("減速あり", waitSeconds: 0.3, intervalSeconds: 0.01) {
                        tap("#counter")
                        return driver.tapCount >= 3
                    }
                }
            }
        }
        XCTAssertTrue(core.finalRecord.passed, "\(sink.steps.map { "\($0.description ?? ""): \($0.detail ?? "")" })")
        XCTAssertEqual(driver.tapCount, 3)
        XCTAssertGreaterThanOrEqual(sink.steps.filter { ($0.pacingMs ?? 0) > 0 }.count, 2, "中の tap の前で実際に待っている")
    }
}
