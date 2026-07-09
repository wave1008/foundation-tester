// ScenarioHostDebugTests.swift
// ScenarioHost.run のデバッグ実行(制御チャネル)の統合テスト。
// 実際に ftester-scenarios-SampleApp サブプロセスを dry-run で起動し、
// 「paused イベントがプロセス存命中に届く」ことを検証する
// (FileHandle.bytes.lines はパイプで EOF まで行を溜めることがあり、
//  一時停止イベントが届かず GUI と相互待ちになる回帰を防ぐ)。

import XCTest
@testable import FTCore

final class ScenarioHostDebugTests: XCTestCase {

    /// onControl / onEvent はどのスレッドから呼ばれてもよいように受け皿をロックで守る
    private final class DebugSessionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _control: ScenarioRunControl?
        private var _pausedIndexes: [Int] = []

        var control: ScenarioRunControl? {
            lock.lock(); defer { lock.unlock() }
            return _control
        }

        func store(_ control: ScenarioRunControl) {
            lock.lock(); defer { lock.unlock() }
            _control = control
        }

        func recordPause(index: Int) {
            lock.lock(); defer { lock.unlock() }
            _pausedIndexes.append(index)
        }

        var pausedIndexes: [Int] {
            lock.lock(); defer { lock.unlock() }
            return _pausedIndexes
        }
    }

    func testPausedEventArrivesWhileProcessAlive() async throws {
        // SampleApp プロジェクトとビルド済みランナーが前提(リポジトリ内での実行)
        let project: TestProject
        do {
            project = try ScenarioHost.project(named: "SampleApp")
            _ = try ScenarioHost.runnerURL(project: project)
        } catch {
            throw XCTSkip("SampleApp のランナーが無いためスキップ: \(error)")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-debug-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let probe = DebugSessionProbe()
        let paused1 = expectation(description: "1 回目の paused がプロセス存命中に届く")
        let paused2 = expectation(description: "step 後の 2 回目の paused が届く")

        let options = ScenarioDebugOptions(breakpoints: [], pauseOnStart: true) { control in
            probe.store(control)
        }
        let runTask = Task {
            await ScenarioHost.run(
                project: project, scenarioID: "ログイン画面.S0010",
                connection: DriverConnection(platform: "ios"),
                heal: false, reportDir: tempDir.path,
                dryRun: true, debug: options) { event in
                if event.kind == "paused" {
                    probe.recordPause(index: event.index ?? 0)
                    switch probe.pausedIndexes.count {
                    case 1: paused1.fulfill()
                    case 2: paused2.fulfill()
                    default: break
                    }
                }
            }
        }

        // ランナーは最初のステップの手前で停止したまま(プロセスは終了しない)。
        // ここで paused が届かなければ「EOF まで溜まる」バグの再発
        await fulfillment(of: [paused1], timeout: 30)

        // step → 2 ステップ目の手前で再停止 → continue で完走
        probe.control?.stepOver()
        await fulfillment(of: [paused2], timeout: 15)
        probe.control?.continueRun()

        let passed = await runTask.value
        XCTAssertTrue(passed, "continue 後は完走して成功するはず")
        XCTAssertEqual(probe.pausedIndexes, [1, 2], "ステップ 1 → 2 の手前で停止するはず")
    }
}
