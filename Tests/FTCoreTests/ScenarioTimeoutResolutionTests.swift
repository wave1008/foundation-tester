// `@Test(scenarioTimeout:)` > 実行プロファイル / `--scenario-timeout` > 既定 の優先順位と、
// ScenarioInfo の往復、ScenarioHost.run での配線(偽ランナーの置き方は ScenarioHostIdleWatchTests と同じ)。

import XCTest
@testable import FTCore

final class ScenarioTimeoutResolutionTests: XCTestCase {

    func testScenarioShorterThanProfileWins() {
        XCTAssertEqual(ScenarioTimeoutResolution.seconds(scenario: 30, settings: 900), 30)
        XCTAssertEqual(ScenarioTimeoutResolution.resolve(scenario: 30, settings: 900).source, .scenario)
    }

    func testScenarioLongerThanProfileWins() {
        XCTAssertEqual(ScenarioTimeoutResolution.seconds(scenario: 1800, settings: 60), 1800)
    }

    func testScenarioNilFallsBackToProfile() {
        let resolved = ScenarioTimeoutResolution.resolve(scenario: nil, settings: 90)
        XCTAssertEqual(resolved.seconds, 90)
        XCTAssertEqual(resolved.source, .profile)
    }

    func testBothNilFallsBackToDefault600() {
        let resolved = ScenarioTimeoutResolution.resolve(scenario: nil, settings: nil)
        XCTAssertEqual(resolved.seconds, 600)
        XCTAssertEqual(resolved.source, .defaultValue)
    }

    func testSourceLabelsAreTheLogVocabulary() {
        XCTAssertEqual(ScenarioTimeoutResolution.Source.scenario.rawValue, "@Test scenarioTimeout")
        XCTAssertEqual(ScenarioTimeoutResolution.Source.profile.rawValue, "run profile scenarioTimeout")
        XCTAssertEqual(ScenarioTimeoutResolution.Source.defaultValue.rawValue, "default")
    }

    func testNonPositiveValueDoesNotTrapInWatchdogDuration() {
        XCTAssertEqual(ScenarioHost.watchdogDuration(
            seconds: ScenarioTimeoutResolution.seconds(scenario: -3, settings: 60)), .seconds(0))
        XCTAssertEqual(ScenarioHost.watchdogDuration(
            seconds: ScenarioTimeoutResolution.seconds(scenario: 0, settings: 60)), .seconds(0))
    }

    func testNonPositiveScenarioValueHasARejectReason() {
        XCTAssertNotNil(ScenarioTimeoutResolution.invalidScenarioValueReason(0))
        XCTAssertNotNil(ScenarioTimeoutResolution.invalidScenarioValueReason(-1))
        XCTAssertNil(ScenarioTimeoutResolution.invalidScenarioValueReason(1))
        XCTAssertNil(ScenarioTimeoutResolution.invalidScenarioValueReason(nil))
    }

    func testScenarioInfoRoundTripWithAndWithoutTimeout() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let with = ScenarioInfo(id: "A.S0010", title: "t", scenarioTimeout: 1800)
        XCTAssertEqual(try decoder.decode(ScenarioInfo.self, from: encoder.encode(with)).scenarioTimeout, 1800)
        let without = ScenarioInfo(id: "A.S0020", title: "t")
        let decoded = try decoder.decode(ScenarioInfo.self, from: encoder.encode(without))
        XCTAssertNil(decoded.scenarioTimeout)
        XCTAssertEqual(decoded, without)
    }
}

final class ScenarioHostPerScenarioTimeoutTests: XCTestCase {

    private var savedPackageRoot: String?
    private var root: URL!

    override func setUpWithError() throws {
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-scn-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let savedPackageRoot { setenv("FT_PACKAGE_ROOT", savedPackageRoot, 1) } else { unsetenv("FT_PACKAGE_ROOT") }
        try? FileManager.default.removeItem(at: root)
    }

    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _logs: [String] = []
        func append(_ event: ScenarioEvent) {
            guard let message = event.message else { return }
            lock.lock(); _logs.append(message); lock.unlock()
        }
        var logs: [String] { lock.lock(); defer { lock.unlock() }; return _logs }
    }

    private func runSleepingChild(name: String, perScenario: Int?, profile: Int?) async throws
        -> (passed: Bool, logs: [String]) {
        let project = TestProject(name: name, rootURL: root.appendingPathComponent("TestProjects/\(name)"))
        let path = root.appendingPathComponent(".build/debug").appendingPathComponent(project.productName)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nsleep 5\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        setenv("FT_PACKAGE_ROOT", root.path, 1)
        let sink = LogSink()
        let passed = await ScenarioHost.run(
            project: project, scenarioID: "Login.S0010",
            connection: DriverConnection(platform: "ios"),
            deviceSession: RunDeviceSession(),
            classHasBeforeAll: false,
            scenarioTimeoutOverride: perScenario,
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false), scenarioTimeout: profile),
            reportDir: root.appendingPathComponent("reports").path) { sink.append($0) }
        return (passed, sink.logs)
    }

    func testPerScenarioTimeoutBeatsLongerProfileTimeout() async throws {
        let result = try await runSleepingChild(name: "PerScenario", perScenario: 1, profile: 60)
        XCTAssertFalse(result.passed)
        let line = result.logs.first { $0.contains("was killed") }
        XCTAssertNotNil(line, "\(result.logs)")
        XCTAssertTrue(line?.hasPrefix("⏱ The scenario exceeded 1s (@Test scenarioTimeout)") == true, "\(line ?? "")")
    }

    /// 式で渡った 0 以下は子を起こさずに赤(起こすと watchdog が 0 秒で即打ち切る)
    func testNonPositiveScenarioValueFailsBeforeLaunch() async throws {
        let started = ContinuousClock.now
        let result = try await runSleepingChild(name: "NonPositive", perScenario: 0, profile: 60)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.logs.contains { $0.contains("must be a positive number of seconds (got 0)") }, "\(result.logs)")
        XCTAssertFalse(result.logs.contains { $0.contains("was killed") }, "\(result.logs)")
        // 子(sleep 5)を起こしていれば 5 秒近くかかる
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    }

    func testProfileTimeoutIsNamedWhenScenarioHasNone() async throws {
        let result = try await runSleepingChild(name: "ProfileOnly", perScenario: nil, profile: 1)
        XCTAssertFalse(result.passed)
        let line = result.logs.first { $0.contains("was killed") }
        XCTAssertTrue(line?.hasPrefix("⏱ The scenario exceeded 1s (run profile scenarioTimeout)") == true, "\(line ?? "")")
    }
}
