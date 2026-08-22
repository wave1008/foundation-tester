import XCTest

@testable import FTDSL
import FTCore

/// チェーンした検証の**初回判定は掴んだ値で行い、満たしていなければ実機で取り直す**契約。
/// 速い側(往復0回)だけを見て満足すると、**古い値で緑になり続ける**穴に気付けないので、
/// 「掴んだ値では不一致 → 取り直したら一致」も必ず通す。
final class HeldValueAssertTests: XCTestCase {

    /// snapshot の回数を数え、指定回数を過ぎるとラベル/値が変わるドライバ
    private final class MutatingDriver: AppDriver {
        /// snapshot() が呼ばれた回数(往復の有無の判定に使う)
        private(set) var snapshotCount = 0
        /// この回数を超えた snapshot から後半の値を返す(0 = 常に前半)
        var mutatesAfter = 0
        var firstLabel = "1,200"
        var secondLabel = "1,500"
        var enabled = true
        var checked: Bool?

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            snapshotCount += 1
            let label = (mutatesAfter > 0 && snapshotCount > mutatesAfter) ? secondLabel : firstLabel
            return SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "staticText", identifier: "total",
                                       label: label, value: label,
                                       placeholder: nil, enabled: enabled,
                                       frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0,
                                       checked: checked)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    /// occlusion-guard(falsePositiveCheck)が実際に走る条件を作るための delegate。
    /// 「見えている」と答えるので、ガードは通るが**走ったこと自体**は snapshot 回数に出る
    private final class VisibleDelegate: ReplayDelegate {
        func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal? { nil }
        func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? { nil }
        func triage(goal: String?, stepDescription: String, failureReason: String,
                    snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? { nil }
        func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                                  screenshotPNG: Data) async
            -> (visible: Bool, state: String, reason: String, observedText: String)? {
            (visible: true, state: "fullyVisible", reason: "", observedText: expectedText)
        }
    }

    private func run(driver: MutatingDriver, delegate: ReplayDelegate? = nil,
                     falsePositiveCheck: Bool = false,
                     _ body: @escaping () -> Void) -> FTDriveCore {
        let core = FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: delegate, healingEnabled: false,
                               falsePositiveCheckEnabled: falsePositiveCheck, dryRun: false,
                               healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-held-assert-test.json"),
                               emit: { _ in })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body() } } }
        return core
    }

    private func steps(_ core: FTDriveCore) -> [DSLStepRecord] {
        core.finalRecord.scenes.flatMap(\.steps)
    }

    /// 高速経路を **run 横断で数えられる形**で emit すること。表示(説明文の括弧書き)だけだと
    /// 「速くなったのは実装のおかげか、この経路の当たり率が上がっただけか」を後から切り分けられない
    func testGrabbedValueStepsEmitTheMachineReadableCode() {
        var events: [ScenarioEvent] = []
        let driver = MutatingDriver()
        let core = FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false,
                               falsePositiveCheckEnabled: false, dryRun: false,
                               healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-held-assert-notes-test.json"),
                               emit: { events.append($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { select("#total").textIs("1,200") } } }
        assertAllPassed(core)

        let steps = events.filter { $0.kind == "step" }
        XCTAssertEqual(steps.count, 2, "select と textIs の 2 ステップ: \(steps.map { $0.description ?? "" })")
        XCTAssertNil(steps.first?.notes, "デバイスを見たステップに高速経路の印が付いている")
        XCTAssertEqual(steps.last?.notes, [StepNote.heldValue.rawValue])
    }

    private func assertAllPassed(_ core: FTDriveCore,
                                 file: StaticString = #filePath, line: UInt = #line) {
        for step in steps(core) {
            if case .failed(let reason) = step.status {
                XCTFail("\(step.description) が落ちた: \(reason)", file: file, line: line)
            }
        }
    }

    // MARK: - 掴んだ値で満たしていれば往復しない

    func testChainedAssertionUsesTheGrabbedValueWithoutAnotherSnapshot() {
        let driver = MutatingDriver()
        let core = run(driver: driver) {
            select("#total").textIs("1,200").textContains("200").valueIs("1,200")
        }
        assertAllPassed(core)
        XCTAssertEqual(driver.snapshotCount, 1,
                       "掴んだ値で判定できるのに取り直している(チェーン3本ぶん往復が増えている)")
        XCTAssertTrue(steps(core).dropFirst().allSatisfy { $0.description.contains("(from the grabbed value)") },
                      "取り直していない判定がレポート上で見分けられない: \(steps(core).map(\.description))")
    }

    /// **3つの書き方は同義**(2026-08-04 ユーザー決定): チェーン / lastElement 明示 / 暗黙。
    /// 記録されるステップも往復回数も一致すること —— ここがズレると「どれで書いたか」で
    /// 結果が変わる DSL になり、書き手は毎回どれを使うか迷うことになる
    func testTheThreeFormsAreEquivalent() {
        func stepsOf(_ body: @escaping () -> Void) -> (steps: [String], snapshots: Int) {
            let driver = MutatingDriver()
            let core = run(driver: driver, body)
            assertAllPassed(core)
            return (steps(core).map(\.description), driver.snapshotCount)
        }
        let chained = stepsOf { select("#total").textIs("1,200") }
        let explicit = stepsOf { select("#total"); lastElement.textIs("1,200") }
        let implicit = stepsOf { select("#total"); textIs("1,200") }

        XCTAssertEqual(chained.steps, explicit.steps, "チェーン形と lastElement 形で記録が違う")
        XCTAssertEqual(chained.steps, implicit.steps, "チェーン形と暗黙形で記録が違う")
        XCTAssertEqual([chained.snapshots, explicit.snapshots, implicit.snapshots], [1, 1, 1],
                       "書き方によってデバイス往復の回数が違う")
    }

    /// 暗黙形にセレクタらしい期待値を渡したら**実行前に落とす**(旧2引数形の書き癖)。
    /// とくに否定形は「そのテキストではない」が常に真になり、黙って緑になる
    func testSelectorLikeExpectedIsRejected() {
        let driver = MutatingDriver()
        let core = run(driver: driver) {
            select("#total")
            textIsNot("#btn_submit")
        }
        guard case .failed(let reason) = steps(core).last?.status else {
            return XCTFail("セレクタらしい期待値が通ってしまった: \(steps(core).map(\.description))")
        }
        XCTAssertTrue(reason.contains("not a selector"), reason)
    }

    // MARK: - 満たしていなければ取り直す(ここが本命)

    /// 掴んだ後に画面が変わったケース: 掴んだ値では不一致 → 取り直して一致 → 成功
    func testStaleValueFallsBackToPollingAndPasses() {
        let driver = MutatingDriver()
        driver.mutatesAfter = 1   // select の1回目だけ "1,200"、以降は "1,500"
        let core = run(driver: driver) {
            select("#total").textIs("1,500")
        }
        assertAllPassed(core)
        XCTAssertGreaterThan(driver.snapshotCount, 1, "掴んだ値で不一致なのに取り直していない")
        XCTAssertFalse(steps(core).last?.description.contains("(from the grabbed value)") ?? true,
                       "取り直したのに「掴んだ値で判定」と記録している")
    }

    /// どちらでも一致しなければ従来どおり落ちる(空振りを緑にしない)
    func testMismatchStillFails() {
        let driver = MutatingDriver()
        let core = run(driver: driver) { select("#total").textIs("9,999", timeout: 0.2) }
        guard case .failed = steps(core).last?.status else {
            return XCTFail("不一致が通ってしまった: \(steps(core).map(\.description))")
        }
    }

    /// 否定形も掴んだ値で判定する(満たしていなければ同じく取り直す)
    func testNegativeAssertionUsesTheGrabbedValue() {
        let driver = MutatingDriver()
        let core = run(driver: driver) { select("#total").textIsNot("9,999") }
        assertAllPassed(core)
        XCTAssertEqual(driver.snapshotCount, 1)
    }

    /// enabled は掴んだ値で判定できる
    func testEnabledUsesTheGrabbedValue() {
        let driver = MutatingDriver()
        let core = run(driver: driver) { select("#total").enabledIsTrue() }
        assertAllPassed(core)
        XCTAssertEqual(driver.snapshotCount, 1)
    }

    /// **checked は掴んだ値で判定しない**(実機経路が「checked を観測したか」を追跡しており、
    /// 飛ばすと checkIsOFF の誤用警告が出なくなるため)
    func testCheckedAlwaysReadsTheDevice() {
        let driver = MutatingDriver()
        driver.checked = true
        let core = run(driver: driver) { select("#total").checkIsON() }
        assertAllPassed(core)
        XCTAssertEqual(driver.snapshotCount, 2, "checked が掴んだ値で判定されている")
    }

    /// **可視性照合(falsePositiveCheck)が走る run では高速経路に入らない**。
    /// 飛ばすと「覆われているのに緑」を検出する検査が静かに1つ消える
    func testVisibilityCheckedRunStillReadsTheDevice() {
        let driver = MutatingDriver()
        let delegate = VisibleDelegate()
        let core = run(driver: driver, delegate: delegate, falsePositiveCheck: true) {
            select("#total").textIs("1,200")
        }
        assertAllPassed(core)
        XCTAssertEqual(driver.snapshotCount, 2,
                       "可視性照合が走る設定なのに掴んだ値で通している")
    }

    /// **FM が無くても(delegate nil)可視性照合が走る設定なら実機を見に行く** —— 幾何の Tier-0
    /// (中心が画面外なら不可視)は FM 無しで効くので、FM の有無で高速経路に入ると
    /// FM の無いホストで幾何の検査が静かに1つ消える
    func testVisibilityCheckedRunReadsTheDeviceEvenWithoutAnFMDelegate() {
        let driver = MutatingDriver()
        let core = run(driver: driver, delegate: nil, falsePositiveCheck: true) {
            select("#total").textIs("1,200")
        }
        assertAllPassed(core)
        XCTAssertEqual(driver.snapshotCount, 2,
                       "FM が無いだけで可視性照合の設定を無視して掴んだ値で通している")
    }

    /// idIs も掴んだ値で判定する(id は画面に描かれず古くなりようがない)
    func testIdIsUsesTheGrabbedValue() {
        let driver = MutatingDriver()
        let core = run(driver: driver) { select("#total").idIs("total") }
        assertAllPassed(core)
        XCTAssertEqual(driver.snapshotCount, 1)
    }
}
