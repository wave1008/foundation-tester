import XCTest
@testable import FTDSL
import FTCore

/// group(共通ステップ)と setUp / tearDown の記録・中断セマンティクス。
/// DSL コマンドはカレントスレッドのグローバル状態を触るため、各テストで bootstrap → tearDown する。
final class FTRuntimeLifecycleTests: XCTestCase {

    /// 常に同じ 1 要素(#cleanup)を返すドライバ。tap の呼び出しだけ記録する
    private final class StubDriver: AppDriver {
        private(set) var tapped: [Int] = []
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "button", identifier: "cleanup", label: nil,
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tapped.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(driver: AppDriver, dryRun: Bool) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: dryRun,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-heal-test.json"),
                    emit: { _ in })
    }

    private func steps(_ core: FTDriveCore) -> [DSLStepRecord] {
        core.finalRecord.scenes.flatMap(\.steps)
    }

    private func isSkipped(_ status: StepResult.Status) -> Bool {
        if case .skipped = status { return true }
        return false
    }

    private func isFailed(_ status: StepResult.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    /// 構文誤りはデバイスに触る前(dry-run でも)に落とす。放置すると誤記が label 扱いになり、
    /// notExist / countIs(x,0) が必ず成功する = 黙って緑になる
    func testInvalidSelectorFailsEvenInDryRun() {
        let core = makeCore(driver: StubDriver(), dryRun: true)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { tap(".Button:near(合計)") }
            }
        }
        let recorded = steps(core)
        XCTAssertTrue(isFailed(recorded[0].status), "未知の記法が dry-run を素通りした")
    }

    /// ifCanSelect は perform を通らないため個別に検証する。構文誤りが「不成立」に化けると
    /// ブロックが飛んだまま緑になる
    func testInvalidSelectorInIfCanSelectFails() {
        let core = makeCore(driver: StubDriver(), dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var executed = false
        scenario {
            scene(1, "s") {
                action {
                    ifCanSelect(".Button:rigth(#cleanup)") { executed = true }
                }
            }
        }
        let recorded = steps(core)
        XCTAssertTrue(isFailed(recorded[0].status), "綴り誤りが不成立扱いになった")
        XCTAssertFalse(executed)
    }

    func testGroupPrefixesStepDescriptions() {
        let core = makeCore(driver: StubDriver(), dryRun: true)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    group("ログイン") {
                        tap("#a")
                        group("入力") { type("#b", "x") }
                    }
                    tap("#c")
                }
            }
        }
        let descriptions = steps(core).map(\.description)
        XCTAssertEqual(descriptions, [
            "[ログイン] tap \"#a\"",
            "[ログイン/入力] type \"#b\" \"x\"",
            "tap \"#c\"",
        ])
    }

    func testTearDownRunsAfterSceneFailure() {
        let driver = StubDriver()
        let core = makeCore(driver: driver, dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    exist("#missing", timeout: 0, requireVisible: false)
                    tap("#cleanup")   // scene 失敗後なのでスキップされる
                }
            }
        }
        ftRunTearDown { tap("#cleanup") }

        let recorded = steps(core)
        XCTAssertTrue(isFailed(recorded[0].status))
        XCTAssertTrue(isSkipped(recorded[1].status), "scene 内の後続はスキップされる(既存の契約)")
        XCTAssertEqual(recorded[2].section, "tearDown")
        XCTAssertFalse(isSkipped(recorded[2].status), "片付けは失敗後でも実行する")
        XCTAssertEqual(driver.tapped, [1], "tearDown の tap だけが実際に発火する")
    }

    func testTearDownFailureIsRecordedAndDoesNotHideSceneFailure() {
        let core = makeCore(driver: StubDriver(), dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tap("#cleanup") } } }
        ftRunTearDown { exist("#missing", timeout: 0, requireVisible: false) }

        XCTAssertFalse(core.finalRecord.passed, "片付けの失敗もシナリオ失敗として残る")
    }

    func testSetUpFailureAbortsScenario() {
        let driver = StubDriver()
        let core = makeCore(driver: driver, dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        ftRunSetUp { exist("#missing", timeout: 0, requireVisible: false) }
        scenario {
            scene(1, "s") { action { tap("#cleanup") } }
            scene(2, "s2") { action { tap("#cleanup") } }
        }

        XCTAssertTrue(driver.tapped.isEmpty, "setUp が失敗したら本体は 1 ステップも実行しない")
        let recorded = steps(core)
        XCTAssertEqual(recorded[0].section, "setUp")
        XCTAssertTrue(isFailed(recorded[0].status))
        // scene(n) の入口は sceneAborted を毎回リセットするので、シナリオ中断へ昇格していないと
        // ここが実行されてしまう(この期待が本テストの主眼)
        XCTAssertTrue(recorded.dropFirst().allSatisfy { isSkipped($0.status) })
    }

    func testSetUpSuccessLeavesScenarioRunnable() {
        let driver = StubDriver()
        let core = makeCore(driver: driver, dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        ftRunSetUp { tap("#cleanup") }
        scenario { scene(1, "s") { action { tap("#cleanup") } } }

        XCTAssertEqual(driver.tapped, [1, 1])
        XCTAssertTrue(core.finalRecord.passed)
    }
}
