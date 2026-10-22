// ステップの減速(HostLoadPacing)の判定・設定・その瞬間の CPU の読み・親の引数・子プロセス境界の配線。
// 期待値は production の定数ではなくリテラルで書く。

import XCTest
import Foundation
@testable import FTCore

final class HostLoadPacingTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private let tiers = [HostLoadPacing.Tier(cpuPercentAtLeast: 90, delayMs: 200),
                         HostLoadPacing.Tier(cpuPercentAtLeast: 95, delayMs: 500)]

    // MARK: - 判定

    func testDelayBoundaries() {
        func delay(_ cpu: Double?) -> Int { HostLoadPacing.delayMs(cpu: cpu, tiers: tiers) }
        XCTAssertEqual(delay(0.8999), 0)
        XCTAssertEqual(delay(0.90), 200)
        XCTAssertEqual(delay(0.9499), 200)
        XCTAssertEqual(delay(0.95), 500)
        XCTAssertEqual(delay(1.0), 500)
        XCTAssertEqual(delay(0.0), 0)
    }

    func testNoDelayWithoutAValueOrTiers() {
        XCTAssertEqual(HostLoadPacing.delayMs(cpu: nil, tiers: tiers), 0, "測れない")
        XCTAssertEqual(HostLoadPacing.delayMs(cpu: 0.99, tiers: []), 0, "段が無い")
    }

    func testTierOrderDoesNotMatter() {
        let reversed = Array(tiers.reversed())
        XCTAssertEqual(HostLoadPacing.delayMs(cpu: 0.97, tiers: reversed), 500)
        XCTAssertEqual(HostLoadPacing.delayMs(cpu: 0.92, tiers: reversed), 200)
    }

    func testOnlyOperationsThatChangeTheScreenArePaced() {
        for action in ["tap", "type", "swipe", "scrollTo", "flick", "holdStart", "pressEnter", "hideKeyboard"] {
            XCTAssertTrue(HostLoadPacing.pacesBefore(action: action, isVerification: false, settle: nil), action)
        }
        for action in ["select", "findImages", "waitForSettle"] {
            XCTAssertFalse(HostLoadPacing.pacesBefore(action: action, isVerification: false, settle: nil), "読むだけ・待つだけ: \(action)")
        }
        XCTAssertFalse(HostLoadPacing.pacesBefore(action: "existImage", isVerification: true, settle: nil), "検証")
        XCTAssertFalse(HostLoadPacing.pacesBefore(action: nil, isVerification: true, settle: nil), "検証")
        XCTAssertFalse(HostLoadPacing.pacesBefore(action: nil, isVerification: false, settle: nil), "action の無いステップ")
        XCTAssertFalse(HostLoadPacing.pacesBefore(action: "tap", isVerification: false, settle: false), "settle: false = 速さ優先")
        XCTAssertTrue(HostLoadPacing.pacesBefore(action: "tap", isVerification: false, settle: true))
    }

    func testDefaultTiersArePinned() {
        XCTAssertEqual(HostLoadPacing.defaultTiers.map(\.cpuPercentAtLeast), [90, 95])
        XCTAssertEqual(HostLoadPacing.defaultTiers.map(\.delayMs), [200, 1000])
        XCTAssertEqual(InstantHostCPU.windowSeconds, 0.01)
    }

    /// 実際に host_processor_info を2回読む(この機械で値が取れ、窓のぶん眠ること)
    func testInstantReadingReturnsAFractionAfterTheWindow() throws {
        var failures: [String] = []
        let reader = InstantHostCPU(logFailure: { failures.append($0) })
        let started = Date()
        let value = try XCTUnwrap(reader.read(), "\(failures)")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.0095, "窓(10ms)を空けて読む")
        XCTAssertTrue((0...1).contains(value))
        XCTAssertNotNil(reader.read(), "続けて読んでも窓を空けるので値が取れる")
    }

    func testResolveDefaultsDisabledAndInvalid() {
        XCTAssertEqual(HostLoadPacing.resolve(nil)?.tiers, HostLoadPacing.defaultTiers, "欄ごと無い = 既定で有効")
        XCTAssertNil(HostLoadPacing.resolve(nil)?.warning)
        XCTAssertEqual(HostLoadPacing.resolve(HostLoadPacing(disabled: false))?.tiers, HostLoadPacing.defaultTiers)
        XCTAssertNil(HostLoadPacing.resolve(HostLoadPacing(disabled: true)))
        XCTAssertEqual(HostLoadPacing.resolve(HostLoadPacing(tiers: []))?.tiers, [], "空 = 待たない")
        let custom = [HostLoadPacing.Tier(cpuPercentAtLeast: 80, delayMs: 10)]
        XCTAssertEqual(HostLoadPacing.resolve(HostLoadPacing(tiers: custom))?.tiers, custom)

        let invalid: [[HostLoadPacing.Tier]] = [
            [.init(cpuPercentAtLeast: 0, delayMs: 10)],
            [.init(cpuPercentAtLeast: 100.5, delayMs: 10)],
            [.init(cpuPercentAtLeast: 90, delayMs: -1)],
            [.init(cpuPercentAtLeast: 90, delayMs: 10), .init(cpuPercentAtLeast: 90, delayMs: 20)],
        ]
        for tiers in invalid {
            let resolved = HostLoadPacing.resolve(HostLoadPacing(tiers: tiers))
            XCTAssertEqual(resolved?.tiers, HostLoadPacing.defaultTiers, "不正は既定の段へ倒す: \(tiers)")
            XCTAssertNotNil(resolved?.warning, "不正は警告する: \(tiers)")
        }
        XCTAssertNil(HostLoadPacing.resolve(HostLoadPacing(tiers: [.init(cpuPercentAtLeast: 100, delayMs: 0)]))?.warning)
    }

    // MARK: - LocalConfig

    func testLocalConfigDecodesHostLoadPacing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostLoadPacingTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"""
        {"hostLoadPacing": {"disabled": true, "tiers": [{"cpuPercentAtLeast": 90, "delayMs": 200},
                                                       {"cpuPercentAtLeast": 95, "delayMs": 500}]}}
        """#.write(to: url, atomically: true, encoding: .utf8)
        let config = LocalConfig.load(from: url)
        XCTAssertEqual(config.hostLoadPacing?.disabled, true)
        XCTAssertEqual(config.hostLoadPacing?.tiers?.count, 2)
        XCTAssertEqual(config.hostLoadPacing?.tiers?.last, .init(cpuPercentAtLeast: 95, delayMs: 500))

        try "{}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(LocalConfig.load(from: url).hostLoadPacing, "無ければ nil(= 既定で有効)")
    }

    // MARK: - 親の引数

    func testParentArgumentsCarryTheEnabledPlanOnlyWithARunDir() throws {
        var warnings: [String] = []
        let args = ScenarioHost.hostLoadPacingArguments(LocalConfig()) { warnings.append($0) }
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args.first, "--host-load-pacing")
        let plan = try JSONDecoder().decode(HostLoadPacingPlan.self, from: Data(try XCTUnwrap(args.last).utf8))
        XCTAssertEqual(plan.tiers, [.init(cpuPercentAtLeast: 90, delayMs: 200), .init(cpuPercentAtLeast: 95, delayMs: 1000)])
        XCTAssertTrue(warnings.isEmpty)

        XCTAssertEqual(ScenarioHost.hostLoadPacingArguments(
            LocalConfig(hostLoadPacing: HostLoadPacing(disabled: true))), [], "disabled")
    }

    func testParentWarnsAndFallsBackToDefaultTiersOnInvalidConfig() throws {
        var warnings: [String] = []
        let config = LocalConfig(hostLoadPacing: HostLoadPacing(tiers: [.init(cpuPercentAtLeast: 0, delayMs: 1)]))
        let args = ScenarioHost.hostLoadPacingArguments(config) {
            warnings.append($0)
        }
        XCTAssertEqual(warnings.count, 1)
        let plan = try JSONDecoder().decode(HostLoadPacingPlan.self, from: Data(try XCTUnwrap(args.last).utf8))
        XCTAssertEqual(plan.tiers.map(\.delayMs), [200, 1000])
    }

    // MARK: - 結果 JSON(ステップの pacingMs とシナリオ単位の集計)

    func testRecordBuilderCarriesPacingMsAndCountsPacedSteps() {
        func step(_ index: Int, pacingMs: Int?) -> ScenarioEvent {
            var event = ScenarioEvent(kind: "step")
            event.index = index
            event.description = "step \(index)"
            event.status = "passed"
            event.pacingMs = pacingMs
            return event
        }
        var builder = ScenarioRecordBuilder(scenarioID: "Foo.a", platform: "ios", title: nil, worker: nil, mode: nil)
        builder.consume(step(1, pacingMs: 201))
        builder.consume(step(2, pacingMs: nil))
        builder.consume(step(3, pacingMs: 502))
        let record = builder.build(passed: true, timedOut: false, startedAt: Date(), durationMs: 1, packageRoot: nil)
        XCTAssertEqual(record.timeline?.map(\.pacingMs), [201, nil, 502])
        XCTAssertEqual(record.steps.paced, 2)
        XCTAssertEqual(record.steps.pacedMs, 703)

        var quiet = ScenarioRecordBuilder(scenarioID: "Foo.b", platform: "ios", title: nil, worker: nil, mode: nil)
        quiet.consume(step(1, pacingMs: nil))
        let none = quiet.build(passed: true, timedOut: false, startedAt: Date(), durationMs: 1, packageRoot: nil)
        XCTAssertNil(none.steps.paced, "1度も待たなかったシナリオは欄ごと無い")
        XCTAssertNil(none.steps.pacedMs)
    }

    // MARK: - 子プロセス境界(型が効かない継ぎ目)

    func testScenarioHostPassesThePlanAndTheRunnerWiresItIntoTheRuntime() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertTrue(host.contains("return [\"--host-load-pacing\", json]"), "--host-load-pacing を子へ渡していない")
        XCTAssertTrue(host.contains("let machineConfig = LocalConfig.load()"), "親がマシンの設定を読んでいない")
        XCTAssertTrue(host.contains("hostLoadPacingArguments(machineConfig)"),
                      "親が設定を読んで渡していない")
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains("customLong(\"host-load-pacing\")"), "--host-load-pacing を受け取れない")
        XCTAssertTrue(runner.contains("let runHostLoadPacing = try Self.decodeHostLoadPacing(hostLoadPacing)"),
                      "--host-load-pacing を復号していない")
        XCTAssertTrue(runner.contains("core.hostLoadPacing = runHostLoadPacing"),
                      "復号した計画を FTDriveCore へ入れていない")
        XCTAssertTrue(runner.contains("core.hostCPUNow = { hostCPU.read() }"), "その瞬間の CPU を測る口を入れていない")
    }
}
