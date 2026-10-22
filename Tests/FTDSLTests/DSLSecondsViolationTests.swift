// FlowStep を通らない DSL の秒数(fold / unfold・ifCanSelect・repeatWhileCanSelect・doUntilTrue)は StepExecutor の入口の
// 検査が効かないので、各コマンドの入口で FlowStep.secondsViolation を当てる。範囲外が届くと FoldControl.apply / IdleAllowance の
// `Int(秒 * 1000)` でテストプロセスごと落ちる(`.infinity` は期限が無くなり止まらない)= 検査を外す変異は中断かハングとして現れる。
// 状態の読みは Android の経路(foldObservation)= simctl / devicectl に触れない。

import XCTest
@testable import FTDSL
@testable import FTCore

final class DSLSecondsViolationTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var steps: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == "step" } }
    }

    /// 開いた状態を答え、送られた角度と撮影を数えるだけ(木は空 = ifCanSelect は見つからない)。
    /// 撮影の回数で「断った」を見ない —— 失敗の記録(handleFailure)が証跡に木を1回撮る
    private final class CountingDriver: AppDriver {
        private let sentCount = LockedValue(0)
        private let snapshotCount = LockedValue(0)
        var hingeSends: Int { sentCount.value }
        var snapshots: Int { snapshotCount.value }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            snapshotCount.withLock { $0 += 1 }
            return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
        func setHingeAngle(degrees: Double) async throws { sentCount.withLock { $0 += 1 } }
        func foldObservation() async -> FoldObservation? { .state(.unfolded) }
    }

    private var sink = Sink()
    private var dir: URL!
    private let violation = "must be a finite, non-negative number of seconds"
    /// 負・非有限・上限(ArgumentBounds.waitSecondsCeiling = 1e15)超え。**`.infinity` は最後** —— 検査が外れると
    /// ifCanSelect 等の待ちが止まらないので、先の値の失敗で止める(continueAfterFailure = false)
    private let outOfRange: [Double] = [-1, .nan, 1e30, .infinity]

    override func setUpWithError() throws {
        continueAfterFailure = false
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-dsl-seconds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func run(_ body: @escaping () -> Void) -> CountingDriver {
        sink = Sink()
        let driver = CountingDriver()
        let core = FTDriveCore(driver: driver, platform: "android", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, tunables: RunTunables(),
                               visionClassifierProjectRoot: dir, dryRun: false,
                               fingerprintCacheURL: dir.appendingPathComponent("fp.json"),
                               emit: { [sink] in sink.add($0) })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario {
            scene(1, "s") {
                action { body() }
            }
        }
        return driver
    }

    private func assertRejected(_ command: String, _ seconds: Double, ranBody: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) {
        let step = sink.steps.first { $0.command == command }
        XCTAssertEqual(step?.status, "failed", "\(command) \(seconds)", file: file, line: line)
        XCTAssertTrue(step?.detail?.contains(violation) == true, "\(command) \(seconds): \(step?.detail ?? "nil")",
                      file: file, line: line)
        XCTAssertFalse(ranBody, "\(command) \(seconds): 断ったら本体を実行しない", file: file, line: line)
    }

    // MARK: - fold / unfold

    func testFoldRejectsOutOfRangeWaitSecondsWithoutSendingTheHinge() {
        for seconds in outOfRange {
            let driver = run { fold(waitSeconds: seconds) }
            XCTAssertEqual(driver.hingeSends, 0, "\(seconds): 断った開閉はヒンジを送らない")
            assertRejected("fold", seconds)
        }
    }

    /// 0 は「待たずに1回だけ確かめる」= 断らずに送る(断りが広すぎる変異を落とす)
    func testUnfoldWithZeroWaitSecondsStillSendsTheHinge() {
        let driver = run { unfold(waitSeconds: 0) }
        XCTAssertEqual(driver.hingeSends, 1)
    }

    // MARK: - ifCanSelect / repeatWhileCanSelect / doUntilTrue

    func testIfCanSelectRejectsOutOfRangeWaitSeconds() {
        for seconds in outOfRange {
            var ran = false
            _ = run { ifCanSelect("#missing", waitSeconds: seconds) { ran = true } }
            assertRejected("ifCanSelect", seconds, ranBody: ran)
        }
    }

    func testRepeatWhileCanSelectRejectsOutOfRangeWaitSeconds() {
        for seconds in outOfRange {
            var ran = false
            _ = run { repeatWhileCanSelect("#missing", waitSeconds: seconds) { ran = true } }
            assertRejected("repeatWhileCanSelect", seconds, ranBody: ran)
        }
    }

    func testDoUntilTrueRejectsOutOfRangeWaitAndIntervalSeconds() {
        for seconds in outOfRange {
            var ran = false
            _ = run { doUntilTrue("w", waitSeconds: seconds) { ran = true; return true } }
            assertRejected("doUntilTrue", seconds, ranBody: ran)
            ran = false
            _ = run { doUntilTrue("i", intervalSeconds: seconds) { ran = true; return true } }
            assertRejected("doUntilTrue", seconds, ranBody: ran)
        }
    }

    /// 境界(0 と上限ちょうど)は断らない。ifCanSelect の 0 は「初回の木だけ見る」既定値そのもの
    func testBoundaryValuesAreAccepted() {
        let driver = run { ifCanSelect("#missing", waitSeconds: 0) {} }
        XCTAssertEqual(driver.snapshots, 1)
        XCTAssertEqual(sink.steps.first { $0.command == "ifCanSelect" }?.status, "skipped")
        var ran = false
        _ = run { doUntilTrue("b", waitSeconds: 1e15, intervalSeconds: 0) { ran = true; return true } }
        XCTAssertTrue(ran)
        XCTAssertEqual(sink.steps.last { $0.command == "doUntilTrue" }?.status, "passed")
    }
}
