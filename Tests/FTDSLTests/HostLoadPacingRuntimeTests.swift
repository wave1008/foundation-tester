// ステップの減速(FTDriveCore.paceBeforeOperation)の挙動: 操作のステップだけが待ち、pacingMs が記録される。

import XCTest
@testable import FTDSL
@testable import FTCore

final class HostLoadPacingRuntimeTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var steps: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == "step" } }
        func kinds(_ kind: String) -> [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == kind } }
    }

    /// 木には hold の対象 `#anchor` が1つだけある
    private final class NullDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [ElementInfo(ref: 1, type: "button", identifier: "anchor", label: nil,
                                                    value: nil, placeholder: nil, enabled: true,
                                                    frame: FTRect(x: 100, y: 200, width: 50, height: 40), depth: 1)],
                             truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func hold(x: Double, y: Double, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private let sink = Sink()
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-pacing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// 段は 95% → delayMs(既定 50ms = テストを速くする)。CPU を測る口は常に cpu を返す(nil = 測れない)
    private func makeCore(dryRun: Bool = false, cpu: Double? = 0.97, delayMs: Int = 50) throws -> FTDriveCore {
        let core = FTDriveCore(driver: NullDriver(), platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(),
                               visionClassifierProjectRoot: dir, dryRun: dryRun,
                               fingerprintCacheURL: dir.appendingPathComponent("fp.json"),
                               emit: { [sink] in sink.add($0) })
        core.hostLoadPacing = HostLoadPacingPlan(tiers: [.init(cpuPercentAtLeast: 95, delayMs: delayMs)])
        core.hostCPUNow = { cpu }
        return core
    }

    func testOperationStepsWaitOnceAndRecordPacingMsWhileVerificationsDoNot() throws {
        // 待ち(1 秒)を NullDriver の tap(数 ms。並列の負荷でも数百 ms)より十分長くし、待ちが計時に入れば durationMs ≥ pacingMs になる形にする
        let core = try makeCore(delayMs: 1000)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        tap(x: 10, y: 10)
        notExist("#nothing-here")
        let steps = sink.steps
        XCTAssertEqual(steps.count, 2)
        let paced = try XCTUnwrap(steps[0].pacingMs, "操作は待つ")
        XCTAssertGreaterThanOrEqual(paced, 995, "実際に眠った時間(段は 1000ms)")
        XCTAssertLessThan(paced, 10_000)
        XCTAssertNil(steps[1].pacingMs, "検証の前には待たない")
        XCTAssertLessThan(try XCTUnwrap(steps[0].durationMs), paced, "待ちは durationMs に含めない(計時の前)")
    }

    func testSelectDoesNotWait() throws {
        let core = try makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        select("#anchor")
        let steps = sink.steps
        XCTAssertEqual(steps.count, 1)
        XCTAssertNil(steps[0].pacingMs, "画面を読むだけのステップの前には待たない")
    }

    func testNothingWaitsWhileAHoldIsDown() throws {
        let core = try makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        hold("#anchor", holdSeconds: 0.1) {
            tap(x: 10, y: 10)
        }
        tap(x: 10, y: 10)
        let steps = sink.steps
        XCTAssertEqual(steps.map { $0.pacingMs != nil }, [true, false, false, true],
                       "押す前と離した後だけ待つ: \(steps.map { $0.description ?? "" })")
    }

    /// 画像で掴んだ要素の tap は見つけた枠の座標を叩くので待たない(待つと座標が古くなる)。
    /// 利用者が書いた座標の tap(x:y:) は画面から読んだ値ではないので待つ
    func testTappingAnElementFoundByImageDoesNotWait() throws {
        let core = try makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        let element = ElementInfo(ref: 1, type: "image", identifier: nil, label: nil, value: nil, placeholder: nil,
                                  enabled: true, frame: FTRect(x: 100, y: 200, width: 50, height: 40), depth: 1)
        let match = FindImage.Match(element: element, visibleFrame: element.frame, distance: 0,
                                    template: URL(fileURLWithPath: "/tmp/template.png"), selector: nil)
        FTElement(imageMatch: match, imageLabel: "anchor").tap()
        tap(x: 10, y: 10)
        XCTAssertEqual(sink.steps.map { $0.pacingMs != nil }, [false, true],
                       "\(sink.steps.map { $0.description ?? "" })")
    }

    /// 減速の待ちはツールの都合の待ち = scenarioTimeout の締め切りから差し引く(deadlineExclusion を親へ流す)
    func testPacingIsExcludedFromTheScenarioDeadline() throws {
        let core = try makeCore(delayMs: 100)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        tap(x: 10, y: 10)
        let exclusions = sink.kinds("deadlineExclusion")
        XCTAssertEqual(exclusions.map { $0.status ?? "" }, ["began", "ended"], "待ちの開始と終わりを両方知らせる")
        XCTAssertGreaterThanOrEqual(exclusions.last?.durationMs ?? 0, 95, "終わりの知らせは実際に待った長さ(段は 100ms)")
    }

    /// settle: false は利用者が速さ優先と明示した操作(消える表示を叩く・連打)なので待たない
    func testASettleFalseOperationDoesNotWait() throws {
        let core = try makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        tap(x: 10, y: 10, settle: false)
        tap(x: 10, y: 10)
        XCTAssertEqual(sink.steps.map { $0.pacingMs != nil }, [false, true])
    }

    func testWaitAndContainersDoNotWait() throws {
        let core = try makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        FTDSL.wait(0.01)  // XCTestCase.wait(for:) と区別する
        procedure("p") {}
        doUntilTrue("t") { true }
        let steps = sink.steps
        XCTAssertEqual(steps.count, 3)
        for step in steps {
            XCTAssertNil(step.pacingMs, "それ自体が操作でないステップの前には待たない: \(step.description ?? "")")
        }
    }

    func testCustomStepsWaitUnlessTheyAreAssertions() throws {
        let core = try makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        core.performCustom(description: "open", command: "openURL", file: #filePath, line: #line) {}
        core.performCustom(description: "is", command: "appIs", file: #filePath, line: #line,
                           isAssertion: true) {}
        let steps = sink.steps
        XCTAssertEqual(steps.count, 2)
        XCTAssertNotNil(steps[0].pacingMs)
        XCTAssertNil(steps[1].pacingMs)
    }

    func testNoWaitInDryRunWithoutAPlanWithLowCPUOrWhenUnmeasurable() throws {
        let dry = try makeCore(dryRun: true)
        XCTAssertEqual(dry.paceBeforeOperation() != nil, true, "判定そのものは dryRun を見ない")

        let core = try makeCore(dryRun: true)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        tap(x: 10, y: 10)
        FTRuntime.tearDown()
        XCTAssertNil(sink.steps.first?.pacingMs, "dry-run では待たない")

        let none = try makeCore()
        none.hostLoadPacing = nil
        XCTAssertNil(none.paceBeforeOperation(), "計画なし")
        XCTAssertNil(try makeCore(cpu: 0.5).paceBeforeOperation(), "段に届かない")
        XCTAssertNil(try makeCore(cpu: nil).paceBeforeOperation(), "測れない")
        let noReader = try makeCore()
        noReader.hostCPUNow = nil
        XCTAssertNil(noReader.paceBeforeOperation(), "測る口が無い")
    }
}
