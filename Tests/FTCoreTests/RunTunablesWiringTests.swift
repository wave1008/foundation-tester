// `RunTunables` は `ScenarioExecutionSettings` に乗って型で守られる区間を通るが、子プロセス境界
// (ScenarioHost の `--tunables` ⇄ ScenarioRunnerMain の復号と使用)だけは型検査が効かない。
// ここが欠けるとプロファイルの値が子に届かず黙って既定で走るので、走査で固定する。
// JSON の往復そのものは RunTunablesBoundaryTests(FTDSLTests)が見る。

import XCTest
@testable import FTCore

final class RunTunablesWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 折り返しで落ちないよう空白を畳んでから見る
    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func testScenarioHostAlwaysForwardsTheTunables() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertTrue(host.contains("let tunables = settings.tunables"), "settings の tunables を読んでいない")
        XCTAssertTrue(host.contains("args += [\"--tunables\", try tunablesArgument(tunables)]"),
                      "--tunables を子へ渡していない(プロファイルの値が子に届かない)")
    }

    func testScenarioRunnerMainUsesTheDecodedTunables() throws {
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains("customLong(\"tunables\")"), "--tunables を受け取れない")
        XCTAssertTrue(runner.contains("let runTunables = try Self.decodeTunables(tunables)"),
                      "--tunables を復号していない")
        XCTAssertTrue(runner.contains("timeoutSeconds: runTunables.injectedAppProbeTimeout"),
                      "起動時プローブの締切に injectedAppProbeTimeout を使っていない")
        XCTAssertTrue(runner.contains("probe.status(timeout: runTunables.injectedAppProbeTimeout)"),
                      "起動時プローブの status の締切に injectedAppProbeTimeout を使っていない")
        XCTAssertTrue(runner.contains("tunables: runTunables,"), "FTDriveCore へ tunables を渡していない")
    }

    /// 実行時に解決する既定は `tunables.<欄>`。固定値へ戻すとプロファイル(将来のキー)で変えても
    /// StepExecutor だけ古い値で動く
    func testStepExecutorNeverFallsBackToTheFixedDefaults() throws {
        let dir = Self.repoRoot.appendingPathComponent("Sources/FTCore")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("StepExecutor") && $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 5, "走査が StepExecutor のファイルに届いていない")
        let constants = ["defaultWaitSeconds", "defaultMaxSwipes", "defaultSwipeDurationSeconds",
                         "defaultFlickDurationSeconds", "defaultFlickIntervalSeconds",
                         "defaultPinchDurationSeconds", "defaultHoldSeconds", "defaultIsScreenWaitSeconds"]
        for constant in constants {
            let offenders = try files.filter {
                try source("Sources/FTCore/\($0)").contains("?? FlowStep.\(constant)")
            }
            XCTAssertEqual(offenders, [], "固定値 FlowStep.\(constant) へのフォールバックが残っている(tunables を使う)")
        }
    }

    /// DSL の既定引数は nil にして `core.tunables` で解く。`= FlowStep.<定数>` の既定引数や
    /// `?? FlowStep.<定数>` が戻ると、その引数だけ実行時の既定に追随しなくなる
    func testDSLNeverBakesInTheFixedDefaults() throws {
        let dir = Self.repoRoot.appendingPathComponent("Sources/FTDSL")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 5, "走査が FTDSL のファイルに届いていない")
        let constants = ["defaultWaitSeconds", "defaultMaxSwipes", "defaultSwipeDurationSeconds",
                         "defaultFlickDurationSeconds", "defaultFlickIntervalSeconds",
                         "defaultPinchDurationSeconds", "defaultHoldSeconds", "defaultIsScreenWaitSeconds"]
        for file in files {
            let text = try source("Sources/FTDSL/\(file)")
            for constant in constants {
                XCTAssertFalse(text.contains("= FlowStep.\(constant)") || text.contains("?? FlowStep.\(constant)"),
                               "\(file): FlowStep.\(constant) を既定に焼き込んでいる(core.tunables を使う)")
            }
        }
    }

    func testDriveCoreHandsTheTunablesToTheExecutor() throws {
        let runtime = try source("Sources/FTDSL/FTRuntime.swift")
        XCTAssertTrue(runtime.contains("tunables: tunables,"), "StepExecutor へ tunables を渡していない")
        XCTAssertTrue(runtime.contains("FTSync.commandTimeout = tunables.commandTimeout"),
                      "commandTimeout を DSL の締切へ反映していない")
        XCTAssertTrue(runtime.contains("commandTimeoutSeconds: tunables.commandTimeout"),
                      "StepExecutor の締切が tunables と別の出どころになっている")
    }
}
