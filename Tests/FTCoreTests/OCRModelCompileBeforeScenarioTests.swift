// 最初のシナリオを起こす前に compile-ocr の完了を待つ(ScenarioHost.awaitOCRModelCompile。ユーザー決定)。
// witness: E2EY-Android の骨組み —— シナリオの中でコンパイルを 39 秒待つ間に 2 秒の読み込み中が終わり、次の検証が本物の行を読んだ。
// 所要は戻り値でなく壁時計で測る(予算のテストの規律)

import Foundation
import XCTest
@testable import FTCore

final class OCRModelCompileBeforeScenarioTests: XCTestCase {

    override func tearDown() {
        ScenarioHost.ocrCompilePID.withLock { $0 = nil }
        super.tearDown()
    }

    private func spawnSleep(_ seconds: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        try process.run()
        ScenarioHost.ocrCompilePID.withLock { $0 = process.processIdentifier }
        return process
    }

    func testWaitsUntilTheCompileChildExits() async throws {
        let child = try spawnSleep("1.5")
        let clock = ContinuousClock()
        let start = clock.now
        let waited = await ScenarioHost.awaitOCRModelCompile()
        let elapsed = clock.now - start
        XCTAssertNotNil(waited)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(1200), "子が生きている間は待つ")
        XCTAssertLessThan(elapsed, .seconds(10))
        XCTAssertFalse(child.isRunning)
    }

    func testDoesNotWaitWithoutACompileChild() async {
        let clock = ContinuousClock()
        let start = clock.now
        let waited = await ScenarioHost.awaitOCRModelCompile()
        XCTAssertNil(waited)
        XCTAssertLessThan(clock.now - start, .milliseconds(100))
    }

    func testStopsWaitingAtTheCap() async throws {
        let child = try spawnSleep("10")
        defer { child.terminate() }
        let clock = ContinuousClock()
        let start = clock.now
        _ = await ScenarioHost.awaitOCRModelCompile(cap: .milliseconds(500))
        let elapsed = clock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(450))
        XCTAssertLessThan(elapsed, .seconds(3), "上限で打ち切る(子が終わるまで待たない)")
    }

    /// 検証スクリプトだけが立てる殺しスイッチ。既定(未設定)は待つ
    func testWaitSwitchDefaultsToWaitingAndOffSkips() {
        XCTAssertTrue(ScenarioHost.waitsForOCRModelCompile(environment: [:]))
        XCTAssertTrue(ScenarioHost.waitsForOCRModelCompile(environment: ["FT_OCR_COMPILE_WAIT": "on"]))
        XCTAssertFalse(ScenarioHost.waitsForOCRModelCompile(environment: ["FT_OCR_COMPILE_WAIT": "off"]))
    }

    func testPinnedCapIsTheModelCompileCap() {
        XCTAssertEqual(RegionText.modelCompileWaitCap, .seconds(120))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 配線: シナリオの所要(startedAt)に含めないよう、計時より前で待つ
    func testScenarioHostRunWaitsBeforeItStartsTiming() throws {
        let source = try source("Sources/FTCore/ScenarioHost.swift")
        let body = try XCTUnwrap(source.range(of: "public static func run(project: TestProject, scenarioID: String,"))
        let rest = source[body.upperBound...]
        let wait = try XCTUnwrap(rest.range(of: "await awaitOCRModelCompileBeforeScenarios"))
        let timing = try XCTUnwrap(rest.range(of: "let startedAt = Date()"))
        XCTAssertLessThan(wait.lowerBound, timing.lowerBound)
    }

    /// 配線: run の経路はシナリオの印(run ボードの経過・残りの起点)より前で待つ。ScenarioHost.run の中だけで
    /// 待つと、何も動いていない間にレーンの経過と残りの秒読みが進む
    func testRunOrchestratorWaitsBeforeTheScenarioMark() throws {
        let source = try source("Sources/FTCore/RunOrchestrator.swift")
        let body = try XCTUnwrap(source.range(of: "private func runWorker(_ worker: RunWorker"))
        let rest = source[body.upperBound...]
        let began = try XCTUnwrap(rest.range(of: "progressState?.ocrCompileWaitBegan()"))
        let joined = try XCTUnwrap(rest.range(of: "progressState?.laneJoined("))
        let wait = try XCTUnwrap(rest.range(of: "await ScenarioHost.awaitOCRModelCompileBeforeScenarios"))
        let ended = try XCTUnwrap(rest.range(of: "progressState?.ocrCompileWaitEnded()"))
        let mark = try XCTUnwrap(rest.range(of: "progressState?.scenarioStarted("))
        XCTAssertLessThan(began.lowerBound, joined.lowerBound, "レーンを見せる最初の記帳から compiling にする")
        XCTAssertLessThan(wait.lowerBound, ended.lowerBound)
        XCTAssertLessThan(ended.lowerBound, mark.lowerBound)
    }

    /// 待ちの判定はスイッチを見る(off の検証スクリプトでは compiling を立てない・待たない)
    func testWaitPendingHonoursTheSwitchAndTheChild() throws {
        XCTAssertFalse(ScenarioHost.isOCRModelCompileWaitPending, "子が居なければ待たない")
        let child = try spawnSleep("5")
        defer { child.terminate() }
        XCTAssertTrue(ScenarioHost.isOCRModelCompileWaitPending)
        let source = try source("Sources/FTCore/ScenarioHost.swift")
        let body = try XCTUnwrap(source.range(of: "static var isOCRModelCompileWaitPending: Bool {"))
        XCTAssertTrue(source[body.upperBound...].prefix(300)
            .contains("waitsForOCRModelCompile(environment: ProcessInfo.processInfo.environment)"))
    }

    /// `_disabled/` を出し入れする検証スクリプトはスイッチを立てる(立てないと run ごとに 35〜42 秒待つ)
    func testVerificationScriptsTurnTheWaitOff() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["heal-verify.sh", "e2e-negative.sh", "fm-verify.sh"] {
            let script = try String(contentsOf: root.appendingPathComponent("Scripts/\(name)"), encoding: .utf8)
            XCTAssertTrue(script.contains("\nexport FT_OCR_COMPILE_WAIT=off\n"), name)
        }
    }
}
