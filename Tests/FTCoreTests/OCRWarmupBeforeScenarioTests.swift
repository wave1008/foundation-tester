// 最初のシナリオを起こす前に warm-ocr の完了を待つ(ScenarioHost.awaitOCRWarmup。ユーザー決定)。
// witness: E2EY-Android の骨組み —— シナリオの中で暖機を 39 秒待つ間に 2 秒の読み込み中が終わり、次の検証が本物の行を読んだ。
// 所要は戻り値でなく壁時計で測る(予算のテストの規律)

import Foundation
import XCTest
@testable import FTCore

final class OCRWarmupBeforeScenarioTests: XCTestCase {

    override func tearDown() {
        ScenarioHost.warmupPID.withLock { $0 = nil }
        super.tearDown()
    }

    private func spawnSleep(_ seconds: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        try process.run()
        ScenarioHost.warmupPID.withLock { $0 = process.processIdentifier }
        return process
    }

    func testWaitsUntilTheWarmupChildExits() async throws {
        let child = try spawnSleep("1.5")
        let clock = ContinuousClock()
        let start = clock.now
        let waited = await ScenarioHost.awaitOCRWarmup()
        let elapsed = clock.now - start
        XCTAssertNotNil(waited)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(1200), "子が生きている間は待つ")
        XCTAssertLessThan(elapsed, .seconds(10))
        XCTAssertFalse(child.isRunning)
    }

    func testDoesNotWaitWithoutAWarmupChild() async {
        let clock = ContinuousClock()
        let start = clock.now
        let waited = await ScenarioHost.awaitOCRWarmup()
        XCTAssertNil(waited)
        XCTAssertLessThan(clock.now - start, .milliseconds(100))
    }

    func testStopsWaitingAtTheCap() async throws {
        let child = try spawnSleep("10")
        defer { child.terminate() }
        let clock = ContinuousClock()
        let start = clock.now
        _ = await ScenarioHost.awaitOCRWarmup(cap: .milliseconds(500))
        let elapsed = clock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(450))
        XCTAssertLessThan(elapsed, .seconds(3), "上限で打ち切る(子が終わるまで待たない)")
    }

    func testPinnedCapIsThePrewarmCap() {
        XCTAssertEqual(RegionText.prewarmWaitCap, .seconds(120))
    }

    /// 配線: シナリオの所要(startedAt)に含めないよう、計時より前で待つ
    func testScenarioHostRunWaitsBeforeItStartsTiming() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/ScenarioHost.swift"), encoding: .utf8)
        let body = try XCTUnwrap(source.range(of: "public static func run(project: TestProject, scenarioID: String,"))
        let rest = source[body.upperBound...]
        let wait = try XCTUnwrap(rest.range(of: "await awaitOCRWarmup()"))
        let timing = try XCTUnwrap(rest.range(of: "let startedAt = Date()"))
        XCTAssertLessThan(wait.lowerBound, timing.lowerBound)
    }
}
