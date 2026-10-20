import XCTest
@testable import FTCore

/// 遅延参加(iOS のブリッジ供給)が1台も合流しなかったら、異常として配布を止める(ユーザー決定: 全滅は異常)。
/// ワーカーを1台も持たない run で確かめる —— シナリオのプロセスを起こさずに、合流の判定・ドレインの理由・
/// summary の欄だけを通せる
final class LateJoinAbortTests: XCTestCase {
    private func makeOrchestrator(
        late: @escaping @Sendable () async -> [RunWorker]
    ) throws -> (RunOrchestrator, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LateJoinAbortTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = TestProject(name: "LateJoinAbort", rootURL: root)
        let orchestrator = RunOrchestrator(
            project: project, workers: [], settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports"),
            progressHistoryRuns: 1, clearResidualSystemAlert: nil,
            lateWorkers: (platforms: ["ios"], provider: late))
        return (orchestrator, root)
    }

    private func item(_ id: String, platform: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: platform))
    }

    private static func skipReasons(_ orchestrator: RunOrchestrator) async -> [String] {
        var reasons: [String] = []
        for await event in orchestrator.events {
            if case .flowSkipped(_, let reason) = event { reasons.append(reason) }
        }
        return reasons
    }

    /// iOS のシナリオが待っているのに iOS が1台も合流しない → 中止理由つきで残りを失敗にする。中断ではない
    func testNoLateJoinerWithPendingScenariosAbortsTheRun() async throws {
        let (orchestrator, _) = try makeOrchestrator(late: { [] })
        async let reasons = Self.skipReasons(orchestrator)
        let summary = await orchestrator.run(
            items: [item("A.S0010", platform: "ios"), item("A.S0020", platform: "ios")], defaultPlatform: "ios")
        let expected = RunOrchestrator.lateJoinAbortReason(platforms: ["ios"])
        XCTAssertEqual(summary.abortReason, expected)
        XCTAssertFalse(summary.interrupted, "ツールが止めた run を利用者の中断として記録している")
        XCTAssertEqual(summary.failed, 2)
        let skipped = await reasons
        XCTAssertEqual(skipped, [expected, expected], "残りのシナリオに中止理由が載っていない")
    }

    /// 合流する OS のシナリオが待っていなければ止めない(その OS の全滅は run の結果に関係しない)
    func testNoLateJoinerWithoutPendingScenariosDoesNotAbort() async throws {
        let (orchestrator, _) = try makeOrchestrator(late: { [] })
        async let reasons = Self.skipReasons(orchestrator)
        let summary = await orchestrator.run(items: [item("A.S0010", platform: "android")], defaultPlatform: "ios")
        _ = await reasons
        XCTAssertNil(summary.abortReason)
        XCTAssertFalse(summary.interrupted)
    }

    /// 中断で合流を待つのをやめた(fallback の [])のは中止ではなく中断
    func testInterruptWhileWaitingForLateJoinIsAnInterruptNotAnAbort() async throws {
        let (orchestrator, _) = try makeOrchestrator(late: {
            try? await Task.sleep(for: .seconds(30))
            return []
        })
        async let reasons = Self.skipReasons(orchestrator)
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            orchestrator.requestInterrupt()
        }
        let summary = await orchestrator.run(items: [item("A.S0010", platform: "ios")], defaultPlatform: "ios")
        let skipped = await reasons
        XCTAssertNil(summary.abortReason)
        XCTAssertTrue(summary.interrupted)
        XCTAssertEqual(skipped, [RunRecorder.interruptedBeforeStartReason])
    }
}
