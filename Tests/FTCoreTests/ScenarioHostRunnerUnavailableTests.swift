// ランナー(シナリオ実行バイナリ)が無い・起こせないときも、シナリオの記録(scenarios/*.json)と
// 直近結果(LastResultsStore)が「失敗」として残ることの検証。
// 以前は log を1行出して false を返すだけで、run.json は失敗を数えるのに scenarios/*.json が無く、
// JUnit と `--failed` からそのシナリオが消えていた。
//
// FT_PACKAGE_ROOT で runnerURL の探索先を一時ディレクトリへ向ける(ScenarioHostPackageRootTests と
// 同じ口)。プロセス全体の env なので同じプロセス内の他テストとは直列(XCTest はクラス内を直列に回す)。

import XCTest
@testable import FTCore

final class ScenarioHostRunnerUnavailableTests: XCTestCase {

    private var savedPackageRoot: String?
    private var root: URL!

    override func setUpWithError() throws {
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-runner-unavailable-\(UUID().uuidString)", isDirectory: true)
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

    /// 1本走らせて、戻り値・記録・直近結果・イベント列をまとめて返す
    private func runOnce(project: TestProject) async -> (passed: Bool, records: [ScenarioRunRecord],
                                                          events: [ScenarioEvent]) {
        let recorder = RunRecorder.begin(project: project, profile: nil, trigger: "test",
                                         captureHostMetrics: false)
        let sink = EventSink()
        let passed = await ScenarioHost.run(
            project: project, scenarioID: "Login.S0010",
            connection: DriverConnection(platform: "ios"),
            fm: FMConfig(enabled: false, heal: false),
            reportDir: root.appendingPathComponent("reports").path,
            recording: ScenarioRecording(recorder: recorder, worker: "ios:iPhone", title: "login")) {
            sink.append($0)
        }
        recorder.finish(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1)
        return (passed, RunResultsStore.records(runDir: recorder.runDir), sink.events)
    }

    private func assertFailedRecord(_ result: (passed: Bool, records: [ScenarioRunRecord],
                                               events: [ScenarioEvent]),
                                    reasonContains needle: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.passed, file: file, line: line)
        XCTAssertEqual(result.records.count, 1, "失敗の記録が1件 scenarios/ に書かれる", file: file, line: line)
        guard let record = result.records.first else { return }
        XCTAssertEqual(record.scenarioID, "Login.S0010", file: file, line: line)
        XCTAssertFalse(record.passed, file: file, line: line)
        XCTAssertEqual(record.timedOut, false, file: file, line: line)
        XCTAssertEqual(record.worker, "ios:iPhone", file: file, line: line)
        XCTAssertEqual(record.steps.failed, 1, file: file, line: line)
        XCTAssertEqual(record.failedSteps?.count, 1, file: file, line: line)
        let step = record.failedSteps?.first
        XCTAssertTrue(step?.description.contains(needle) == true,
                      "理由が失敗ステップに載る: \(step?.description ?? "nil")", file: file, line: line)
        // ドライバにもアプリにも触っていない失敗に既存の種別を当てない(結果 JSON は事実だけ)
        XCTAssertNil(step?.failureKind, file: file, line: line)
        XCTAssertTrue(record.errorLogs?.contains { $0.hasPrefix("❌") && $0.contains(needle) } == true,
                      "❌ の log も errorLogs に残る: \(record.errorLogs ?? [])", file: file, line: line)
        // 呼び出し側(集計・モニター)には通常の失敗と同じ scenarioFinished(passed:false) が届く
        let finished = result.events.filter { $0.kind == "scenarioFinished" }
        XCTAssertEqual(finished.count, 1, file: file, line: line)
        XCTAssertEqual(finished.first?.passed, false, file: file, line: line)
        XCTAssertEqual(finished.first?.scenario, "Login.S0010", file: file, line: line)
    }

    /// ランナーが見つからない(ビルドされていない): runnerNotFound
    func testMissingRunnerBinaryWritesAFailedRecord() async throws {
        // Package.swift の無いディレクトリを指す = packageRoot() は nil → `.build/debug` も
        // `swift build --show-bin-path` も探さない(テストから swift build を起こさない)
        setenv("FT_PACKAGE_ROOT", root.path, 1)
        let project = TestProject(name: "NoSuchProduct-\(UUID().uuidString.prefix(8))",
                                  rootURL: root.appendingPathComponent("TestProjects/NoSuch"))

        let result = await runOnce(project: project)

        assertFailedRecord(result, reasonContains: "not found")
        XCTAssertTrue(LastResultsStore.failedIDs(project: project).contains("Login.S0010"),
                      "`--failed` の材料(直近結果)にも失敗として残る")
    }

    /// ランナーは「実行可能ファイルとして見つかる」が起動できない: Process.run() の throw。
    /// `.build/debug/<product>` に**ディレクトリ**を置く —— access(X_OK) は通るので runnerURL は
    /// これを返し、posix_spawn は EACCES で落ちる(空の +x ファイルだと環境によって /bin/sh へ
    /// 倒れて exit 0 になりうるので使わない)
    func testUnlaunchableRunnerWritesAFailedRecord() async throws {
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let project = TestProject(name: "Unlaunchable",
                                  rootURL: root.appendingPathComponent("TestProjects/Unlaunchable"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build/debug").appendingPathComponent(project.productName),
            withIntermediateDirectories: true)
        setenv("FT_PACKAGE_ROOT", root.path, 1)
        XCTAssertNoThrow(try ScenarioHost.runnerURL(project: project), "前提: 探索はディレクトリを掴む")

        let result = await runOnce(project: project)

        assertFailedRecord(result, reasonContains: "Cannot start the runner")
        XCTAssertTrue(LastResultsStore.failedIDs(project: project).contains("Login.S0010"))
    }

    /// dry-run は従来どおり記録対象外(false は返すが scenarios/ には書かない・直近結果も触らない)
    func testDryRunDoesNotRecord() async throws {
        setenv("FT_PACKAGE_ROOT", root.path, 1)
        let project = TestProject(name: "NoSuchDry-\(UUID().uuidString.prefix(8))",
                                  rootURL: root.appendingPathComponent("TestProjects/NoSuchDry"))
        let recorder = RunRecorder.begin(project: project, profile: nil, trigger: "test",
                                         captureHostMetrics: false)
        let passed = await ScenarioHost.run(
            project: project, scenarioID: "Login.S0010",
            connection: DriverConnection(platform: "ios"),
            fm: FMConfig(enabled: false, heal: false),
            reportDir: root.appendingPathComponent("reports").path,
            dryRun: true,
            recording: ScenarioRecording(recorder: recorder)) { _ in }
        XCTAssertFalse(passed)
        XCTAssertTrue(RunResultsStore.records(runDir: recorder.runDir).isEmpty)
        XCTAssertFalse(LastResultsStore.failedIDs(project: project).contains("Login.S0010"))
    }
}
