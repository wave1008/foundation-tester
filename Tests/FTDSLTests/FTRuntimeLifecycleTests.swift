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

    /// thisIs 系は perform を通らないため個別に検証する。dry-run と失敗後の扱いを
    /// DSL コマンドと揃えないと、列挙だけのはずの dry-run に ❌ が出る/失敗後も検証が走る
    func testValueAssertionsFollowDryRunAndAbortSemantics() {
        let dry = makeCore(driver: StubDriver(), dryRun: true)
        FTRuntime.bootstrap(core: dry, dslThread: Thread.current)
        scenario {
            scene(1, "s") { action { "abc".thisIs("zzz") } }
        }
        XCTAssertFalse(isFailed(steps(dry)[0].status), "dry-run で実値を判定した")
        FTRuntime.tearDown()

        let live = makeCore(driver: StubDriver(), dryRun: false)
        FTRuntime.bootstrap(core: live, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario {
            scene(1, "s") {
                action {
                    "abc".thisIs("zzz")   // ここで失敗 → シナリオ中断
                    "abc".thisIs("abc")   // 後続はスキップ(実行しない)
                }
            }
        }
        let recorded = steps(live)
        XCTAssertTrue(isFailed(recorded[0].status))
        XCTAssertTrue(isSkipped(recorded[1].status), "失敗後も検証が走った")
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

    /// 失敗したら**次の scene も実行しない**(2026-07-27 変更。以前は scene 単位でスキップし
    /// 次の scene へ進んでいた)。失敗後の画面状態は不定で、続けても壊れた前提の擬陽性/擬陰性を
    /// 量産するだけのため、シナリオ全体を中断する
    func testFailureAbortsWholeScenario() {
        let driver = StubDriver()
        let core = makeCore(driver: driver, dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "失敗する") {
                action { exist("#missing", timeout: 0, requireVisible: false) }
            }
            scene(2, "実行されない") {
                action { tap("#cleanup") }
            }
        }
        let recorded = steps(core)
        XCTAssertTrue(isFailed(recorded[0].status))
        XCTAssertTrue(isSkipped(recorded[1].status), "失敗後の scene が実行された")
        XCTAssertTrue(driver.tapped.isEmpty)
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
                    tap("#cleanup")   // 失敗後なのでスキップされる
                }
            }
        }
        ftRunTearDown { tap("#cleanup") }

        let recorded = steps(core)
        XCTAssertTrue(isFailed(recorded[0].status))
        XCTAssertTrue(isSkipped(recorded[1].status), "失敗後の後続はスキップされる")
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

    // MARK: - 値の読み出し(FTElement.text/value/id)

    /// 掴めなかった場合は .text/.value/.id が nil のまま(値の有無で「見つかった」を判定できるように)
    func testExistNotFoundLeavesValuesNil() {
        let core = makeCore(driver: StubDriver(), dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var element: FTElement!
        scenario {
            scene(1, "s") {
                action { element = exist("#missing", timeout: 0, requireVisible: false) }
            }
        }
        XCTAssertNil(element.text)
        XCTAssertNil(element.value)
        XCTAssertNil(element.id)
    }

    /// 失敗後にスキップされた exist も値は nil(実行していないので読める値が無い)
    func testExistAfterFailureReturnsNilValues() {
        let core = makeCore(driver: StubDriver(), dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var element: FTElement!
        scenario {
            scene(1, "s") {
                action {
                    exist("#missing", timeout: 0, requireVisible: false)   // 失敗 → シナリオ中断
                    element = exist("#cleanup")   // 中断後なのでスキップされる
                }
            }
        }
        XCTAssertTrue(isSkipped(steps(core)[1].status))
        XCTAssertNil(element.text)
        XCTAssertNil(element.id)
    }

    /// dry-run はデバイスに触れないため値は読めない(列挙専用の契約は変えない)
    func testExistInDryRunReturnsNilValues() {
        let core = makeCore(driver: StubDriver(), dryRun: true)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var element: FTElement!
        scenario {
            scene(1, "s") { action { element = exist("#cleanup") } }
        }
        XCTAssertNil(element.text)
        XCTAssertNil(element.id)
    }

    // MARK: - DSL スレッド外からの誤呼び出し(procedure { } で包み忘れた Task 等)

    /// スレッド違反は fatalError にせず、失敗ステップを1件だけ記録してシナリオを中断する。
    /// 以降のコマンドは既存の skip 経路に乗り、2回目以降の違反で記録が増えないこと・
    /// プロセスが生きたまま結果を持ち帰れることを固定する
    func testThreadViolationIsRecordedOnceAndAbortsWithoutCrashing() {
        let driver = StubDriver()
        let core = makeCore(driver: driver, dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        let violatingThread = Thread {
            // ループから呼ばれた体で2回呼ぶ。2回目以降で記録が増えないことを見る
            tap("#cleanup")
            tap("#cleanup")
        }
        violatingThread.start()
        while !violatingThread.isFinished {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let recorded = steps(core)
        XCTAssertEqual(recorded.filter { isFailed($0.status) }.count, 1,
                       "スレッド違反の記録が1回に固定されていない")
        XCTAssertTrue(recorded.contains { isSkipped($0.status) },
                      "違反後のコマンドが skipped として記録されていない")
        XCTAssertTrue(driver.tapped.isEmpty,
                      "違反スレッドから実際にドライバへ操作が飛んでしまった(プロセスは生きているべきだが実行はしない)")
    }

    // MARK: - 秒粒度(小数 timeout / waitSeconds)

    /// timeout に 1.2 のような小数を渡せること自体が Int → Double 移行の固定点
    /// (型が Int に戻ると本テストがコンパイルできなくなる)。実行結果も通常どおりであることを見る
    func testFractionalTimeoutCompilesAndPassesThroughNormally() {
        let core = makeCore(driver: StubDriver(), dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action { exist("#cleanup", timeout: 1.2) }
            }
        }
        XCTAssertTrue(core.finalRecord.passed)
    }

    /// ifCanSelect(waitSeconds: 0.3) が 0.5 秒刻みに丸められないこと。
    /// 丸められる旧実装(Thread.sleep(0.5) 固定)だと不成立確定までの実測が ~0.5s 以上になるが、
    /// 新実装は残り時間と 0.25s の小さい方で待つため ~0.3s で確定する
    func testIfCanSelectDoesNotRoundFractionalWaitSecondsTo0Point5() {
        let core = makeCore(driver: StubDriver(), dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        let start = Date()
        scenario {
            scene(1, "s") {
                action { ifCanSelect("#definitely_missing", waitSeconds: 0.3) {} }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.48, "0.5 秒刻みに丸められている(実測 \(elapsed)s)")
    }
}
