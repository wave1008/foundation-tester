// ft_start_run / ft_run_status の純粋部分: 引数の組み立て・run の突き合わせ・状態の文面。
// 実際に `swift run` を起こす経路はここでは撃たない(ビルドを伴うため)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPRunJobsTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-run-jobs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - argv

    func testArgumentsWithEveryOption() {
        let args = MCPRunJobs.arguments(
            profile: "smoke", project: "Shop", runner: "M1Max", scenarios: ["Login", "Cart.add"],
            folders: ["checkout"], failed: true, broadcast: true)
        XCTAssertEqual(args, [
            "swift", "run", "fleetest", "run", "--project", "Shop", "--profile", "smoke", "--runner", "M1Max",
            "--scenario", "Login", "Cart.add", "--folder", "checkout", "--failed", "--broadcast",
        ])
    }

    func testArgumentsOmitUnsetOptionals() {
        let args = MCPRunJobs.arguments(
            profile: "smoke", project: nil, runner: nil, scenarios: [], folders: [], failed: false, broadcast: false)
        XCTAssertEqual(args, ["swift", "run", "fleetest", "run", "--profile", "smoke"])
    }

    /// MCP は承認なしで呼ばれうるので、登録していない宛先へは送らない(local と登録名だけ)
    func testRunnerAcceptsOnlyLocalAndRegisteredMachines() {
        XCTAssertNil(MCPRunJobs.runnerRefusal("local", registered: []))
        XCTAssertNil(MCPRunJobs.runnerRefusal("M1Max", registered: ["M1Max", "M1Ultra"]))
        XCTAssertNotNil(MCPRunJobs.runnerRefusal("wave@192.168.20.101", registered: ["M1Max"]))
        XCTAssertNotNil(MCPRunJobs.runnerRefusal("192.168.20.101", registered: ["M1Max"]))
        XCTAssertNotNil(MCPRunJobs.runnerRefusal("M1Mini", registered: []))
    }

    func testCommandLineQuotesArgumentsWithSpaces() {
        XCTAssertEqual(MCPRunJobs.commandLine(["swift", "run", "--profile", "my profile"]),
                       "env swift run --profile \"my profile\"")
    }

    func testChildEnvironmentCarriesTheParentPIDAndBothRoots() {
        let env = MCPRunJobs.childEnvironment(
            packageRoot: URL(fileURLWithPath: "/work"), toolRoot: URL(fileURLWithPath: "/tool"),
            base: ["PATH": "/usr/bin"])
        XCTAssertEqual(env[ParentDeathWatch.environmentKey], String(getpid()))
        XCTAssertEqual(env["FT_PACKAGE_ROOT"], "/work")
        XCTAssertEqual(env["FT_TOOL_ROOT"], "/tool")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertNil(MCPRunJobs.childEnvironment(packageRoot: URL(fileURLWithPath: "/work"),
                                                 toolRoot: nil, base: [:])["FT_TOOL_ROOT"])
    }

    func testStartRunValidatesItsArguments() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        XCTAssertThrowsError(try server.startRun([:])) {
            XCTAssertTrue($0.localizedDescription.contains("profile is required"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try server.startRun(["profile": "p", "scenario": "Login"])) {
            XCTAssertTrue($0.localizedDescription.contains("scenario must be an array"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try server.startRun(["profile": "p", "folder": [""]])) {
            XCTAssertTrue($0.localizedDescription.contains("folder[0] must not be empty"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try server.startRun(["profile": "p", "failed": "yes"])) {
            XCTAssertTrue($0.localizedDescription.contains("failed must be a boolean"), $0.localizedDescription)
        }
    }

    /// 子の `fleetest run` でフラグとして読まれる値を断る(`--scenario` は upToNextOption なので、
    /// 2つ目の値の `--runner=` が runnerRefusal を素通りして登録外の機械へ送れていた)。
    /// 入口の配線ごと確かめるため startRun を通す(spawn の前に断るので子は起きない)
    func testStartRunRefusesValuesThatTheChildWouldParseAsOptions() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        let cases: [([String: Any], String)] = [
            (["profile": "p", "scenario": ["A.b", "--runner=evil@example.invalid"]], "scenario[1] must not start with \"-\""),
            (["profile": "p", "folder": ["--junit=/tmp/x.xml"]], "folder[0] must not start with \"-\""),
            (["profile": "--set=sandbox"], "profile must not start with \"-\""),
            (["profile": "p", "runner": " -oProxyCommand=x"], "runner must not start with \"-\""),
        ]
        for (args, expected) in cases {
            XCTAssertThrowsError(try server.startRun(args), "\(args)") {
                XCTAssertTrue($0.localizedDescription.contains(expected), $0.localizedDescription)
            }
        }
    }

    func testOptionLikeValueRefusalPassesOrdinaryValues() {
        XCTAssertNil(MCPRunJobs.optionLikeValueRefusal(
            profile: "ios-sim", runner: "M1Ultra", scenarios: ["Login.test-1", "Cart"], folders: ["smoke/a-b"]))
        XCTAssertNil(MCPRunJobs.optionLikeValueRefusal(profile: "p", runner: nil, scenarios: [], folders: []))
    }

    func testStatusAndStopRefuseUnknownPIDs() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        XCTAssertThrowsError(try server.runStatus([:])) {
            XCTAssertTrue($0.localizedDescription.contains("no run has been started"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try server.stopRun(["pid": 1])) {
            XCTAssertTrue($0.localizedDescription.contains("not a run started by this server"),
                          $0.localizedDescription)
        }
    }

    // MARK: - 突き合わせ

    private let spawnedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: spawnedAt.addingTimeInterval(offset))
    }

    /// 本番の `runIDFloor` を通さず独立に runID を作る(下限の計算を本番と同じ式で検算しない)
    private func runID(_ offset: TimeInterval, suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: spawnedAt.addingTimeInterval(offset)) + "Z-" + suffix
    }

    private func progress(pid: Int32, profile: String = "smoke", project: String = "Shop",
                          startedOffset: TimeInterval = 5) -> RunProgressRecord {
        RunProgressRecord(pid: pid, runID: nil, runGroup: nil, issuer: nil, project: project, profile: profile,
                          startedAt: iso(startedOffset), total: 10, done: 3, failed: 1, requeued: 0,
                          laneDropouts: 0, etaSeconds: nil, lanes: [], phase: "running")
    }

    func testProgressPrefersTheExactPID() {
        let records = [progress(pid: 200, startedOffset: 9), progress(pid: 100, startedOffset: 5)]
        XCTAssertEqual(MCPRunJobs.matchProgress(records, pid: 100, project: "Shop", profile: "smoke",
                                                spawnedAt: spawnedAt)?.pid, 100)
    }

    func testProgressFallsBackToTheNewestSameProfileStartedAfterTheSpawn() {
        let records = [
            progress(pid: 1, startedOffset: -600),                  // 起こす前の古い run
            progress(pid: 2, profile: "other", startedOffset: 8),   // 別プロファイル
            progress(pid: 3, project: "Else", startedOffset: 8),    // 別プロジェクト
            progress(pid: 4, startedOffset: 6),
            progress(pid: 5, startedOffset: 7),
        ]
        XCTAssertEqual(MCPRunJobs.matchProgress(records, pid: 99, project: "Shop", profile: "smoke",
                                                spawnedAt: spawnedAt)?.pid, 5)
        XCTAssertNil(MCPRunJobs.matchProgress(Array(records.prefix(3)), pid: 99, project: "Shop",
                                              profile: "smoke", spawnedAt: spawnedAt))
    }

    private func meta(id: String, pid: Int?, profile: String = "smoke", project: String = "Shop",
                      startedOffset: TimeInterval) -> (meta: RunMetaRecord, dir: URL) {
        (RunMetaRecord(runID: id, project: project, profile: profile, host: "h", trigger: "cli",
                       startedAt: iso(startedOffset), pid: pid),
         tempDir.appendingPathComponent(id))
    }

    func testRunMetaPrefersThePIDThenTheNewestAfterTheSpawn() {
        let runs = [
            meta(id: "old", pid: 100, startedOffset: -3600),            // 起こす前
            meta(id: "other-profile", pid: nil, profile: "x", startedOffset: 10),
            meta(id: "newest", pid: 555, startedOffset: 30),
            meta(id: "mine", pid: 100, startedOffset: 8),
        ]
        XCTAssertEqual(MCPRunJobs.matchRunMeta(runs, pid: 100, project: "Shop", profile: "smoke",
                                               spawnedAt: spawnedAt)?.meta.runID, "mine")
        XCTAssertEqual(MCPRunJobs.matchRunMeta(runs, pid: 999, project: "Shop", profile: "smoke",
                                               spawnedAt: spawnedAt)?.meta.runID, "newest")
        XCTAssertNil(MCPRunJobs.matchRunMeta(Array(runs.prefix(2)), pid: 100, project: "Shop",
                                             profile: "smoke", spawnedAt: spawnedAt))
    }

    func testRunMetaToleratesTheOneSecondTruncationOfStartedAt() {
        let runs = [meta(id: "edge", pid: nil, startedOffset: -0.5)]
        XCTAssertEqual(MCPRunJobs.matchRunMeta(runs, pid: 1, project: "Shop", profile: "smoke",
                                               spawnedAt: spawnedAt)?.meta.runID, "edge")
    }

    func testCandidateRunsReadsOnlyRunsFromTheSpawnOnwards() {
        let newID = runID(10, suffix: "aaaaaaaa")
        let oldID = runID(-3600, suffix: "bbbbbbbb")
        for (id, offset) in [(newID, 10.0), (oldID, -3600.0)] {
            RunResultsStore.writeMeta(
                RunMetaRecord(runID: id, project: "Shop", profile: "smoke", host: "h", trigger: "cli",
                              startedAt: iso(offset)),
                runDir: RunResultsStore.runDir(resultsDir: tempDir, runID: id))
        }
        let found = MCPRunJobs.candidateRuns(resultsDir: tempDir, spawnedAt: spawnedAt, now: spawnedAt)
        XCTAssertEqual(found.map(\.meta.runID), [newID])
    }

    // MARK: - 文面(実エンコーダで書いた fixture から)

    func testFinishedStatusListsTheFailedScenariosWithReportPaths() throws {
        let id = runID(10, suffix: "cccccccc")
        let runDir = RunResultsStore.runDir(resultsDir: tempDir, runID: id)
        RunResultsStore.writeMeta(
            RunMetaRecord(runID: id, project: "Shop", profile: "smoke", host: "h", trigger: "cli",
                          startedAt: iso(10), finishedAt: iso(60), pid: 100, total: 3, passed: 1, failed: 2,
                          interrupted: true),
            runDir: runDir)
        func record(_ scenario: String, passed: Bool, skip: ScenarioSkipKind? = nil,
                    steps: [FailedStepRecord]? = nil, report: String? = nil) -> ScenarioRunRecord {
            ScenarioRunRecord(runID: id, scenarioID: scenario, platform: "ios", host: "h",
                              passed: passed, startedAt: iso(11), durationMs: 5,
                              steps: StepCountsRecord(), reportPath: report, failedSteps: steps,
                              skipKind: skip)
        }
        RunResultsStore.writeScenario(record("A.ok", passed: true), runDir: runDir, fileName: "A.ok")
        RunResultsStore.writeScenario(
            record("B.bad", passed: false,
                   steps: [FailedStepRecord(index: 1, description: "tap #x", detail: "element not found")],
                   report: "TestProjects/Shop/reports/b.html"),
            runDir: runDir, fileName: "B.bad")
        RunResultsStore.writeScenario(record("C.na", passed: false, skip: .notApplicable),
                                      runDir: runDir, fileName: "C.na")
        RunResultsStore.writeScenario(record("D.none", passed: false), runDir: runDir, fileName: "D.none")

        let failures = MCPRunJobs.failedScenarios(records: RunResultsStore.records(runDir: runDir),
                                                  packageRoot: URL(fileURLWithPath: "/work"))
        XCTAssertEqual(failures.map(\.id), ["B.bad", "D.none"], "対象外の合成レコードは失敗に数えない")
        XCTAssertEqual(failures[0].reportPath, "/work/TestProjects/Shop/reports/b.html")
        XCTAssertEqual(failures[0].reason, "element not found")

        let text = MCPRunJobs.statusText(MCPRunStatusInput(
            pid: 100, state: .exited(1), elapsedSeconds: 75, project: "Shop", profile: "smoke",
            logPath: "/log", logTail: ["last line"], progress: nil,
            meta: try XCTUnwrap(RunResultsStore.meta(runDir: runDir)), runDirPath: runDir.path,
            failedScenarios: failures))
        XCTAssertTrue(text.contains("finished with exit code 1 (elapsed 1m 15s)"), text)
        XCTAssertTrue(text.contains("1 passed / 2 failed / 3 total — interrupted"), text)
        XCTAssertTrue(text.contains("Results: \(runDir.path)"), text)
        XCTAssertTrue(text.contains("- B.bad (ios): element not found — report: /work/TestProjects/Shop/reports/b.html"), text)
        XCTAssertTrue(text.contains("- D.none (ios)"), text)
        XCTAssertTrue(text.contains("last line"), text)
    }

    func testRunningStatusShowsProgressOrSaysItIsNotAvailableYet() {
        func input(_ progress: RunProgressRecord?) -> MCPRunStatusInput {
            MCPRunStatusInput(pid: 7, state: .running, elapsedSeconds: 12, project: "Shop", profile: "smoke",
                              logPath: "/log", logTail: [], progress: progress, meta: nil,
                              runDirPath: nil, failedScenarios: [])
        }
        let withProgress = MCPRunJobs.statusText(input(progress(pid: 7)))
        XCTAssertTrue(withProgress.contains("running (elapsed 12s)"), withProgress)
        XCTAssertTrue(withProgress.contains("Progress: 3/10 done, 1 failed, phase: running"), withProgress)
        XCTAssertTrue(MCPRunJobs.statusText(input(nil)).contains("not available yet"))
    }

    func testSignaledAndNoRecordStatus() {
        let text = MCPRunJobs.statusText(MCPRunStatusInput(
            pid: 7, state: .signaled(15), elapsedSeconds: 3, project: "Shop", profile: "smoke",
            logPath: "/log", logTail: [], progress: nil, meta: nil, runDirPath: nil, failedScenarios: []))
        XCTAssertTrue(text.contains("stopped by signal 15"), text)
        XCTAssertTrue(text.contains("No run record was found"), text)
    }

    func testFailedListIsCapped() {
        let many = (0..<25).map { MCPFailedScenario(id: "S\($0)", platform: "ios", reason: nil, reportPath: nil) }
        let text = MCPRunJobs.statusText(MCPRunStatusInput(
            pid: 7, state: .exited(1), elapsedSeconds: 3, project: "Shop", profile: "smoke",
            logPath: "/log", logTail: [], progress: nil,
            meta: RunMetaRecord(runID: "r", project: "Shop", profile: "smoke", host: "h", trigger: "cli",
                                startedAt: iso(0)),
            runDirPath: "/r", failedScenarios: many))
        XCTAssertTrue(text.contains("(+5 more"), text)
        XCTAssertFalse(text.contains("- S20 "), text)
    }

    /// 全デバイス実行が始まる前に中断された run は、同じ行が台数ぶん並ぶ → 1行に束ねて台数を言う
    func testIdenticalFailuresAcrossDevicesAreGroupedIntoOneRow() {
        let interrupted = "the run was interrupted (SIGINT/SIGTERM) before this scenario started"
        let failures = [
            MCPFailedScenario(id: "ログイン.S0010", platform: "ios", reason: interrupted, reportPath: nil),
            MCPFailedScenario(id: "ログイン.S0010", platform: "ios", reason: interrupted, reportPath: nil),
            MCPFailedScenario(id: "ログイン.S0010", platform: "ios", reason: interrupted, reportPath: nil),
            MCPFailedScenario(id: "ログイン.S0010", platform: "android", reason: interrupted, reportPath: nil),
            MCPFailedScenario(id: "ログイン.S0010", platform: "ios", reason: "element not found", reportPath: nil),
        ]
        let groups = MCPRunJobs.groupedFailures(failures)
        XCTAssertEqual(groups.map(\.count), [3, 1, 1], "初出順・(ID, platform, 理由)が鍵")
        XCTAssertEqual(MCPRunJobs.failureRow(groups[0]), "- ログイン.S0010 (ios) on 3 devices: \(interrupted)")
        XCTAssertEqual(MCPRunJobs.failureRow(groups[1]), "- ログイン.S0010 (android): \(interrupted)")
    }

    func testGroupedRowListsFewReportsAndAbbreviatesMany() {
        func failures(_ n: Int) -> [MCPFailedScenario] {
            (1...n).map { MCPFailedScenario(id: "A.b", platform: "ios", reason: "boom", reportPath: "/r/\($0).html") }
        }
        XCTAssertEqual(MCPRunJobs.failureRow(MCPRunJobs.groupedFailures(failures(1))[0]),
                       "- A.b (ios): boom — report: /r/1.html")
        XCTAssertEqual(MCPRunJobs.failureRow(MCPRunJobs.groupedFailures(failures(3))[0]),
                       "- A.b (ios) on 3 devices: boom — reports: /r/1.html, /r/2.html, /r/3.html")
        XCTAssertEqual(MCPRunJobs.failureRow(MCPRunJobs.groupedFailures(failures(5))[0]),
                       "- A.b (ios) on 5 devices: boom — report: /r/1.html (+4 more)")
    }

    /// 上限(`failedListLimit`)は束ねた後の行に掛かる: 同じ失敗が何台あっても1行
    func testFailedListLimitAppliesToGroupedRows() {
        let same = (0..<30).map { _ in MCPFailedScenario(id: "S", platform: "ios", reason: "x", reportPath: nil) }
        let text = MCPRunJobs.statusText(MCPRunStatusInput(
            pid: 7, state: .exited(1), elapsedSeconds: 3, project: "Shop", profile: "smoke",
            logPath: "/log", logTail: [], progress: nil,
            meta: RunMetaRecord(runID: "r", project: "Shop", profile: "smoke", host: "h", trigger: "cli",
                                startedAt: iso(0)),
            runDirPath: "/r", failedScenarios: same))
        XCTAssertTrue(text.contains("- S (ios) on 30 devices: x"), text)
        XCTAssertFalse(text.contains("more —"), text)
    }

    func testLogTailKeepsTheLastLines() throws {
        let url = tempDir.appendingPathComponent("run.log")
        try (1...100).map { "line \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let tail = MCPRunJobs.logTail(url: url)
        XCTAssertEqual(tail.count, MCPRunJobs.logTailLines)
        XCTAssertEqual(tail.last, "line 100")
        XCTAssertEqual(tail.first, "line 71")
        XCTAssertEqual(MCPRunJobs.logTail(url: tempDir.appendingPathComponent("missing.log")), [])
    }

    func testRegistryTracksExitsEvenWhenRecordedBeforeAdd() {
        let registry = MCPRunJobRegistry()
        registry.recordExit(pid: 42, reason: .exit, status: 3)
        XCTAssertEqual(registry.state(of: 42).state, .exited(3))
        XCTAssertEqual(registry.state(of: 43).state, .running)
        registry.recordExit(pid: 44, reason: .uncaughtSignal, status: 15)
        XCTAssertEqual(registry.state(of: 44).state, .signaled(15))
    }
}
