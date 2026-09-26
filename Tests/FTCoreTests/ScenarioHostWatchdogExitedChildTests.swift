// `ScenarioHost.run` の watchdog は、締め切りの時点で**子が既に終わっている**なら打ち切らない。
// 実害(2026-09-17 の負荷テスト): 親(api run / リモートの run)が一時停止している間に子が緑で
// 完走し、親の再開と同時に watchdog が「exceeded 180s and was killed」を確定して、子の
// scenarioFinished(passed)を捨てていた(レポート .md は ✅・結果 DB は赤)。
//
// 親を止める代わりに「子は緑を出してすぐ終わるが、孫が stdout を握って EOF を遅らせる」形で
// 同じ状況(締め切りの時点で子は死んでいて、読み取りループはまだ終わっていない)を作る。

import XCTest
@testable import FTCore

private let testFMSettings = FMSettingsRecord(
    heal: false, fmTextOcclusionCheck: false, screenLooksLike: true, ocrTextOcclusionCheck: true)

final class ScenarioHostWatchdogExitedChildTests: XCTestCase {

    private var savedPackageRoot: String?
    private var root: URL!

    override func setUpWithError() throws {
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-watchdog-exited-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let savedPackageRoot { setenv("FT_PACKAGE_ROOT", savedPackageRoot, 1) } else { unsetenv("FT_PACKAGE_ROOT") }
        try? FileManager.default.removeItem(at: root)
    }

    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [ScenarioEvent] = []
        func append(_ event: ScenarioEvent) { lock.lock(); _events.append(event); lock.unlock() }
        var events: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    }

    private func writeRunner(project: TestProject, script: String) throws {
        let path = root.appendingPathComponent(".build/debug").appendingPathComponent(project.productName)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(script)\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private func runOnce(project: TestProject, scenarioTimeout: Int) async
        -> (passed: Bool, record: ScenarioRunRecord?, events: [ScenarioEvent]) {
        let recorder = RunRecorder.begin(project: project, profile: nil, trigger: "test",
                                         captureHostMetrics: false)
        let sink = EventSink()
        let passed = await ScenarioHost.run(
            project: project, scenarioID: "Login.S0010",
            connection: DriverConnection(platform: "ios"),
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false),
                                                scenarioTimeout: scenarioTimeout),
            reportDir: root.appendingPathComponent("reports").path,
            recording: ScenarioRecording(recorder: recorder)) { sink.append($0) }
        recorder.finish(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1,
                        performanceMode: false, fmSettings: testFMSettings, setOverrides: nil)
        return (passed, RunResultsStore.records(runDir: recorder.runDir).first, sink.events)
    }

    /// 子は即座に緑で終わる。孫(stdout を継いだ `sleep 3`)が EOF を 3 秒遅らせるので、
    /// 1 秒の watchdog は「子が既に終わった後」に締め切りを迎える
    func testWatchdogDoesNotTimeOutAChildThatAlreadyExited() async throws {
        let project = TestProject(name: "ExitedChild",
                                  rootURL: root.appendingPathComponent("TestProjects/ExitedChild"))
        try writeRunner(project: project, script: """
            echo '{"kind":"scenarioFinished","passed":true}'
            sleep 3 &
            exit 0
            """)
        setenv("FT_PACKAGE_ROOT", root.path, 1)

        let result = await runOnce(project: project, scenarioTimeout: 1)

        XCTAssertTrue(result.passed, "子は 1 秒以内に緑で終わっているのに timeout として赤にした")
        XCTAssertNotEqual(result.record?.timedOut, true)
        XCTAssertFalse(result.events.contains { ($0.message ?? "").contains("was killed") },
                       "終わっている子に「killed」を言っている")
        let finished = result.events.filter { $0.kind == "scenarioFinished" }
        XCTAssertEqual(finished.map(\.passed), [true], "子の scenarioFinished がそのまま 1 回だけ流れるはず")
    }

    /// 対照: 子自身が生きたまま締め切りを越えたら、従来どおり打ち切る
    /// (上のテストが「watchdog が一切発火しない」変異で素通りしないため)
    func testWatchdogStillKillsAChildThatIsStillRunning() async throws {
        let project = TestProject(name: "LiveChild",
                                  rootURL: root.appendingPathComponent("TestProjects/LiveChild"))
        try writeRunner(project: project, script: """
            sleep 3
            echo '{"kind":"scenarioFinished","passed":true}'
            """)
        setenv("FT_PACKAGE_ROOT", root.path, 1)

        let result = await runOnce(project: project, scenarioTimeout: 1)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.record?.timedOut, true)
    }
}
