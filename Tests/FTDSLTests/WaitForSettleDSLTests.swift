// waitForSettle の DSL の写像(FTCore の単体は FlowStep を直接作るので、DSL 側の渡し忘れ・反転は通ってしまう):
// 戻り値(静止したか)/ 既定の waitSeconds = tunables / throwsException の写像と注記 / 範囲の要素は lastElement を
// 差し替えない / 解決できない範囲は常に失敗 / 書き戻し(ScenarioCodeGen)。

import XCTest
@testable import FTDSL
@testable import FTCore

final class WaitForSettleDSLTests: XCTestCase {

    private static let listFrame = FTRect(x: 10, y: 20, width: 300, height: 400)

    /// waitForSettle の要求と応答を記録するドライバ。木は list と other の2要素で固定
    private final class SettleDriver: AppDriver {
        var responses: [WaitForSettleResponse] = []
        private(set) var requests: [WaitForSettleRequest] = []

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [
                    ElementInfo(ref: 1, type: "staticText", identifier: "list", label: "一覧", value: nil,
                                placeholder: nil, enabled: true, frame: WaitForSettleDSLTests.listFrame, depth: 0),
                    ElementInfo(ref: 2, type: "button", identifier: "other", label: "別", value: nil,
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 600, width: 100, height: 20), depth: 0),
                ],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
        func waitForSettle(_ request: WaitForSettleRequest, timeoutSeconds: Double) async throws -> WaitForSettleResponse {
            requests.append(request)
            guard !responses.isEmpty else { return WaitForSettleResponse(settled: true, elapsedMs: 800, frames: 3) }
            return responses[min(requests.count - 1, responses.count - 1)]
        }
    }

    private final class EventBox {
        var events: [ScenarioEvent] = []
        var steps: [ScenarioEvent] { events.filter { $0.kind == "step" } }
    }

    private func unsettled() -> WaitForSettleResponse {
        WaitForSettleResponse(settled: false, elapsedMs: 15000, frames: 90,
                              lastChangeRegion: FTRect(x: 1, y: 2, width: 3, height: 4))
    }

    /// DSL スレッドで scene 1本ぶんを走らせる(section は action = XCTestCase.expectation との名前衝突を避ける)
    private func run(_ driver: SettleDriver, tunables: RunTunables = RunTunables(),
                     _ body: @escaping () -> Void) -> (core: FTDriveCore, box: EventBox) {
        let box = EventBox()
        let core = FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: tunables, dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-waitforsettle-dsl-test.json"),
                               emit: { box.events.append($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body() } } }
        return (core, box)
    }

    func testSelectorRegionAndQuietSecondsReachTheBridgeAndSettledReturnsTrue() {
        let driver = SettleDriver()
        var settled = false
        let (core, box) = run(driver) { settled = waitForSettle("#list", quietSeconds: 1.2) }
        XCTAssertTrue(settled)
        XCTAssertTrue(core.finalRecord.passed)
        XCTAssertEqual(driver.requests.first?.region, Self.listFrame)
        XCTAssertEqual(driver.requests.first?.quietMs, 1200)
        let step = box.steps.last
        XCTAssertEqual(step?.command, "waitForSettle")
        XCTAssertEqual(step?.description, "waitForSettle \"#list\" (quiet 1.2s)")
    }

    func testTheTypedSelectorOverloadMeansTheSame() {
        let driver = SettleDriver()
        var settled = false
        _ = run(driver) { settled = waitForSettle(Sel.id("list")) }
        XCTAssertTrue(settled)
        XCTAssertEqual(driver.requests.first?.region, Self.listFrame)
    }

    /// 省略した waitSeconds は tunables.screenWaitTimeout で解く(DSL に固定の 15 を焼き込まない)
    func testNoSelectorMeansTheWholeScreenAndTheScreenWaitTunableIsTheDefault() throws {
        let driver = SettleDriver()
        _ = run(driver, tunables: RunTunables(screenWaitTimeout: 7)) { waitForSettle() }
        let sent = try XCTUnwrap(driver.requests.first)
        XCTAssertNil(sent.region)
        XCTAssertTrue((6500...7000).contains(sent.timeoutMs), "\(sent.timeoutMs)")

        let explicit = SettleDriver()
        _ = run(explicit, tunables: RunTunables(screenWaitTimeout: 7)) { waitForSettle(waitSeconds: 3) }
        XCTAssertTrue((2500...3000).contains(try XCTUnwrap(explicit.requests.first).timeoutMs))
    }

    func testUnsettledAbortsTheScenarioByDefaultAndReturnsFalse() {
        let driver = SettleDriver()
        driver.responses = [unsettled()]
        var results: [Bool] = []
        let (core, box) = run(driver) {
            results.append(waitForSettle())
            results.append(waitForSettle())
        }
        XCTAssertEqual(results, [false, false])
        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertEqual(driver.requests.count, 1, "失敗したら以降のステップは実行しない")
        let failed = box.steps.first { $0.status == "failed" }
        XCTAssertEqual(failed?.failureKind, "timeout")
    }

    func testThrowsExceptionFalseReturnsFalseKeepsTheScenarioGoingAndLeavesTheNote() {
        let driver = SettleDriver()
        driver.responses = [unsettled(), WaitForSettleResponse(settled: true, elapsedMs: 800, frames: 3)]
        var results: [Bool] = []
        let (core, box) = run(driver) {
            results.append(waitForSettle(throwsException: false))
            results.append(waitForSettle(throwsException: false))
        }
        XCTAssertEqual(results, [false, true])
        XCTAssertTrue(core.finalRecord.passed)
        XCTAssertEqual(box.steps.count, 2)
        XCTAssertEqual(box.steps.first?.notes, ["settle-not-reached"])
        XCTAssertNil(box.steps.last?.notes)
    }

    /// 範囲を決めるだけで要素を掴んだわけではない: `select → waitForSettle → lastElement` は select の要素のまま
    func testTheRegionElementDoesNotReplaceLastElement() {
        let driver = SettleDriver()
        var held: FTElement!
        _ = run(driver) {
            select("#other")
            waitForSettle("#list")
            held = lastElement
        }
        XCTAssertEqual(held.id, "other")
    }

    func testAnUnresolvableRegionFailsEvenWithThrowsExceptionFalse() {
        let driver = SettleDriver()
        var settled = true
        let (core, _) = run(driver) { settled = waitForSettle("#missing", throwsException: false, waitSeconds: 0) }
        XCTAssertFalse(settled)
        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertTrue(driver.requests.isEmpty)
    }

    func testOutOfRangeArgumentsFailTheStepWithoutTouchingTheBridge() {
        let driver = SettleDriver()
        let (core, _) = run(driver) { waitForSettle(quietSeconds: 0.05) }
        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertTrue(driver.requests.isEmpty)
    }

    // MARK: - ft_batch / ft_draft_scenario の書き戻し

    func testCodeGenWritesTheArgumentsInDSLOrderAndOmitsTheDefaults() {
        XCTAssertEqual(ScenarioCodeGen.command(for: FlowStep(action: "waitForSettle")), "waitForSettle()")
        XCTAssertEqual(
            ScenarioCodeGen.command(for: FlowStep(action: "waitForSettle", locator: FlowLocator(id: "list"),
                                                  timeout: 5, quietSeconds: 1.2, throwsException: false)),
            "waitForSettle(\"#list\", quietSeconds: 1.2, throwsException: false, waitSeconds: 5)")
        XCTAssertEqual(
            ScenarioCodeGen.command(for: FlowStep(action: "waitForSettle", throwsException: true)),
            "waitForSettle()", "throwsException の既定 true は書かない")
    }
}
