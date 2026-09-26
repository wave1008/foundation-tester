// `ScenarioHost.run` の scenarioTimeout(壁時計 watchdog)は、子が emit する
// deadlineExclusion(began/ended)ぶんだけ締め切りを延ばす(RegionText.awaitPrewarm がその待ちを
// 締め切りから差し引くための仕組み。ScenarioEvent.swift のコメント参照)。
// **延長できるのは実際に差し引かれた分だけ**(打ち切りの意味は変えない)ことと、
// **deadlineExclusion イベントは installRequest と同じく emit(onEvent)へ渡らない**
// (fleetest api の NDJSON 契約に現れない)ことを、実際に子プロセス(偽ランナー)を起こして確かめる。
//
// FT_PACKAGE_ROOT で runnerURL の探索先を一時ディレクトリへ向ける(ScenarioHostRegisterChildProcessTests
// と同じ口)。

import XCTest
@testable import FTCore

private let testFMSettings = FMSettingsRecord(
    heal: false, fmTextOcclusionCheck: false, screenLooksLike: true, ocrTextOcclusionCheck: true)

final class ScenarioHostDeadlineExclusionTests: XCTestCase {

    private var savedPackageRoot: String?
    private var root: URL!

    override func setUpWithError() throws {
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-deadline-exclusion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    /// `body` をそのまま子の stdout として吐く偽ランナー(sh スクリプト)を置く
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
        let records = RunResultsStore.records(runDir: recorder.runDir)
        return (passed, records.first, sink.events)
    }

    /// **差し引きが無い**対照: 1 秒の watchdog に対して 3 秒かかる子は、従来どおり打ち切られる
    /// (この対照が壊れていると、下の「延長される」テストは何も検証していないことになる)
    func testWithoutDeadlineExclusionTheWatchdogStillKillsASlowChild() async throws {
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let project = TestProject(name: "SlowNoExclusion",
                                  rootURL: root.appendingPathComponent("TestProjects/SlowNoExclusion"))
        try writeRunner(project: project, script: "sleep 3\necho '{\"kind\":\"scenarioFinished\",\"passed\":true}'\n")
        setenv("FT_PACKAGE_ROOT", root.path, 1)

        let result = await runOnce(project: project, scenarioTimeout: 1)

        XCTAssertFalse(result.passed, "1 秒の watchdog なのに 3 秒の子が完走している")
        XCTAssertEqual(result.record?.timedOut, true)
        XCTAssertTrue(result.events.allSatisfy { $0.kind != "deadlineExclusion" },
                      "deadlineExclusion は emit へ渡らないはず")
    }

    /// **差し引きあり**: 子が deadlineExclusion(began→ended、実測 2 秒分)を挟めば、
    /// 1 秒の watchdog でも打ち切られずに完走する。かつイベントは emit へ渡らない
    func testDeadlineExclusionExtendsTheWatchdogPastTheOriginalTimeout() async throws {
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let project = TestProject(name: "SlowWithExclusion",
                                  rootURL: root.appendingPathComponent("TestProjects/SlowWithExclusion"))
        try writeRunner(project: project, script: """
            echo '{"kind":"deadlineExclusion","status":"began","durationMs":10000}'
            sleep 2
            echo '{"kind":"deadlineExclusion","status":"ended","durationMs":2000}'
            echo '{"kind":"scenarioFinished","passed":true}'
            """)
        setenv("FT_PACKAGE_ROOT", root.path, 1)

        let result = await runOnce(project: project, scenarioTimeout: 1)

        XCTAssertTrue(result.passed, "差し引き区間(2秒)があるのに 1 秒の watchdog で打ち切られている")
        XCTAssertNotEqual(result.record?.timedOut, true)
        XCTAssertTrue(result.events.allSatisfy { $0.kind != "deadlineExclusion" },
                      "deadlineExclusion は emit へ渡らないはず(installRequest と同じ扱い)")
        let finished = result.events.filter { $0.kind == "scenarioFinished" }
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.passed, true)
    }
}
