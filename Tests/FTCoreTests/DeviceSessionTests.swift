// RunDeviceSession(デバイスごとのメモと setUpDevice の済み印)と DeviceSessionHandoff の単体テスト。
// 末尾の ScenarioHost 結合は偽ランナー(sh)で、子の stdin 1行目と memoWrite の横取りを確かめる。

import XCTest
@testable import FTCore

final class DeviceSessionTests: XCTestCase {

    private func event(_ kind: String, key: String? = nil, value: String? = nil,
                       status: String? = nil) -> ScenarioEvent {
        var e = ScenarioEvent(kind: kind)
        e.memoKey = key
        e.memoValue = value
        e.status = status
        return e
    }

    func testClassNameOfScenarioID() {
        XCTAssertEqual(RunDeviceSession.className(ofScenarioID: "Login.S0010"), "Login")
        XCTAssertEqual(RunDeviceSession.className(ofScenarioID: "Login"), "Login")
        XCTAssertEqual(RunDeviceSession.className(ofScenarioID: "A.b.c"), "A")
    }

    func testFirstHandoffRunsSetUpDeviceAndCarriesMemo() {
        let session = RunDeviceSession()
        let handoff = session.handoff(className: "Login")
        XCTAssertEqual(handoff?.runSetUpDevice, true)
        XCTAssertEqual(handoff?.memo, [:])
        XCTAssertEqual(handoff?.cmd, "deviceSession")
    }

    func testPassedSetUpIsNotRunAgain() {
        let session = RunDeviceSession()
        XCTAssertTrue(session.apply(event("deviceSetUp", status: "began"), className: "Login"))
        XCTAssertTrue(session.apply(event("deviceSetUp", status: "passed"), className: "Login"))
        session.scenarioEnded(className: "Login")
        XCTAssertEqual(session.handoff(className: "Login")?.runSetUpDevice, false)
    }

    func testFailedSetUpBlocksTheClass() {
        let session = RunDeviceSession()
        session.apply(event("deviceSetUp", status: "began"), className: "Login")
        session.apply(event("deviceSetUp", status: "failed"), className: "Login")
        XCTAssertNil(session.handoff(className: "Login"))
    }

    func testBeganWithoutOutcomeBecomesFailedAtScenarioEnd() {
        let session = RunDeviceSession()
        session.apply(event("deviceSetUp", status: "began"), className: "Login")
        session.scenarioEnded(className: "Login")
        XCTAssertNil(session.handoff(className: "Login"))
    }

    func testNotAttemptedClassKeepsRunningSetUpAfterScenarioEnded() {
        let session = RunDeviceSession()
        session.scenarioEnded(className: "Plain")
        XCTAssertEqual(session.handoff(className: "Plain")?.runSetUpDevice, true)
    }

    func testClassesAreIndependent() {
        let session = RunDeviceSession()
        session.apply(event("deviceSetUp", status: "failed"), className: "A")
        session.apply(event("deviceSetUp", status: "passed"), className: "B")
        XCTAssertNil(session.handoff(className: "A"))
        XCTAssertEqual(session.handoff(className: "B")?.runSetUpDevice, false)
        XCTAssertEqual(session.handoff(className: "C")?.runSetUpDevice, true)
    }

    func testMemoKeepsWriteOrderAndClearEmptiesAll() {
        let session = RunDeviceSession()
        XCTAssertTrue(session.apply(event("memoWrite", key: "user", value: "a"), className: "X"))
        session.apply(event("memoWrite", key: "user", value: "b"), className: "X")
        session.apply(event("memoWrite", key: "other", value: "z"), className: "X")
        session.apply(event("memoWrite", key: nil, value: "ignored"), className: "X")
        session.apply(event("memoWrite", key: "k", value: nil), className: "X")
        XCTAssertEqual(session.handoff(className: "Y")?.memo, ["user": ["a", "b"], "other": ["z"]])
        XCTAssertTrue(session.apply(event("memoClear"), className: "X"))
        XCTAssertEqual(session.handoff(className: "Y")?.memo, [:])
    }

    func testOtherEventKindsAreNotConsumed() {
        let session = RunDeviceSession()
        XCTAssertFalse(session.apply(event("step"), className: "X"))
        XCTAssertFalse(session.apply(event("scenarioFinished"), className: "X"))
    }

    func testBookReturnsSameSessionPerKey() {
        let book = RunDeviceSessionBook()
        let a1 = book.session(for: "iPhone-01")
        let a2 = book.session(for: "iPhone-01")
        let b = book.session(for: "Pixel-01")
        XCTAssertTrue(a1 === a2)
        XCTAssertFalse(a1 === b)
    }

    func testHandoffRoundTrip() {
        let original = DeviceSessionHandoff(memo: ["k": ["1", "2"]], runSetUpDevice: true)
        let decoded = DeviceSessionHandoff.decode(line: original.encodedLine())
        XCTAssertEqual(decoded, original)
    }

    func testHandoffDecodeRejectsOtherCmd() {
        XCTAssertNil(DeviceSessionHandoff.decode(
            line: #"{"cmd":"installResult","memo":{},"runSetUpDevice":false}"#))
        XCTAssertNil(DeviceSessionHandoff.decode(line: "not json"))
    }

    func testDeclaredTearDownsAreTakenOnceInDeclarationOrder() {
        let session = RunDeviceSession()
        XCTAssertTrue(session.apply(event("deviceTearDown", status: "declared"), className: "Cart"))
        session.apply(event("deviceTearDown", status: "declared"), className: "Login")
        session.apply(event("deviceTearDown", status: "declared"), className: "Cart")
        XCTAssertEqual(session.takePendingTearDowns(), ["Cart", "Login"])
        XCTAssertEqual(session.takePendingTearDowns(), [])
        // 片付けの後に申告が来ても同じデバイスでは2回目を走らせない
        session.apply(event("deviceTearDown", status: "declared"), className: "Cart")
        XCTAssertEqual(session.takePendingTearDowns(), [])
    }

    func testUndeclaredClassIsNotTornDown() {
        let session = RunDeviceSession()
        session.apply(event("deviceSetUp", status: "began"), className: "Login")
        session.apply(event("deviceSetUp", status: "passed"), className: "Login")
        XCTAssertEqual(session.takePendingTearDowns(), [])
    }

    func testTearDownHandoffNeverRunsSetUpEvenAfterSetUpFailed() {
        let session = RunDeviceSession()
        session.apply(event("memoWrite", key: "k", value: "v"), className: "Login")
        session.apply(event("deviceSetUp", status: "failed"), className: "Login")
        XCTAssertEqual(session.tearDownHandoff(),
                       DeviceSessionHandoff(memo: ["k": ["v"]], runSetUpDevice: false))
    }
}

final class ScenarioHostDeviceSessionTests: XCTestCase {

    private var savedPackageRoot: String?
    private var root: URL!

    override func setUpWithError() throws {
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-device-session-\(UUID().uuidString)", isDirectory: true)
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

    func testMemoWriteIsAppliedNotForwardedAndHandoffIsFirstStdinLine() async throws {
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let project = TestProject(name: "SessionHost",
                                  rootURL: root.appendingPathComponent("TestProjects/SessionHost"))
        let path = root.appendingPathComponent(".build/debug").appendingPathComponent(project.productName)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 子はサンドボックスの中で動くので、観測は書ける出力先へ書かせる
        let received = root.appendingPathComponent("reports/stdin-first-line.txt").path
        let script = """
        #!/bin/sh
        read first
        printf '%s\\n' "$first" > '\(received)'
        echo '{"kind":"memoWrite","memoKey":"token","memoValue":"abc"}'
        echo '{"kind":"deviceSetUp","status":"began"}'
        echo '{"kind":"deviceSetUp","status":"passed"}'
        echo '{"kind":"scenarioFinished","passed":true}'
        """
        try (script + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        setenv("FT_PACKAGE_ROOT", root.path, 1)

        let session = RunDeviceSession()
        let sink = EventSink()
        let passed = await ScenarioHost.run(
            project: project, scenarioID: "Login.S0010",
            connection: DriverConnection(platform: "ios"),
            deviceSession: session,
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports").path) { sink.append($0) }

        XCTAssertTrue(passed)
        let first = try String(contentsOfFile: received, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(DeviceSessionHandoff.decode(line: first),
                       DeviceSessionHandoff(memo: [:], runSetUpDevice: true))
        XCTAssertFalse(sink.events.contains { ["memoWrite", "memoClear", "deviceSetUp"].contains($0.kind) })
        let next = session.handoff(className: "Login")
        XCTAssertEqual(next, DeviceSessionHandoff(memo: ["token": ["abc"]], runSetUpDevice: false))
    }

    func testScenarioIsNotRunWhenSetUpDeviceFailedEarlier() async throws {
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let project = TestProject(name: "SessionHostFailed",
                                  rootURL: root.appendingPathComponent("TestProjects/SessionHostFailed"))
        setenv("FT_PACKAGE_ROOT", root.path, 1)
        let session = RunDeviceSession()
        var failed = ScenarioEvent(kind: "deviceSetUp")
        failed.status = "failed"
        session.apply(failed, className: "Login")

        let sink = EventSink()
        let passed = await ScenarioHost.run(
            project: project, scenarioID: "Login.S0010",
            connection: DriverConnection(platform: "ios"),
            deviceSession: session,
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports").path) { sink.append($0) }

        XCTAssertFalse(passed)
        XCTAssertTrue(sink.events.contains {
            ($0.message ?? "").contains("setUpDevice of Login failed earlier on this device")
        })
    }

    func testDeviceTearDownRunsTheClassOnceInATearDownOnlyChild() async throws {
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let project = TestProject(name: "SessionTearDown",
                                  rootURL: root.appendingPathComponent("TestProjects/SessionTearDown"))
        let path = root.appendingPathComponent(".build/debug").appendingPathComponent(project.productName)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let argsFile = root.appendingPathComponent("reports/args.txt").path
        let script = """
        #!/bin/sh
        read first
        printf '%s\\n' "$*" >> '\(argsFile)'
        echo '{"kind":"step","status":"failed","description":"tap \\"#btn_logout\\"","detail":"not found"}'
        echo '{"kind":"scenarioFinished","passed":false,"reportPath":"/tmp/r.md"}'
        exit 1
        """
        try (script + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        setenv("FT_PACKAGE_ROOT", root.path, 1)

        let session = RunDeviceSession()
        var declared = ScenarioEvent(kind: "deviceTearDown")
        declared.status = "declared"
        session.apply(declared, className: "Login")
        let settings = ScenarioExecutionSettings(fm: FMConfig(enabled: false))
        let reportDir = root.appendingPathComponent("reports").path
        let outcomes = await ScenarioHost.runDeviceTearDowns(
            project: project, connection: DriverConnection(platform: "ios"), deviceSession: session,
            settings: settings, reportDir: reportDir, dryRun: false,
            appPath: nil, appName: nil, appBundleID: nil, registerChildProcess: nil)
        XCTAssertEqual(outcomes.map(\.className), ["Login"])
        XCTAssertEqual(outcomes.first?.passed, false)
        XCTAssertEqual(outcomes.first?.failure, "tap \"#btn_logout\": not found")
        XCTAssertEqual(outcomes.first?.reportPath, "/tmp/r.md")
        let args = try String(contentsOfFile: argsFile, encoding: .utf8)
        XCTAssertTrue(args.contains("--scenario Login "), args)
        XCTAssertTrue(args.contains("--device-teardown-only"), args)
        // 2回目は子を起こさない(引数の記録が1行のまま)
        let again = await ScenarioHost.runDeviceTearDowns(
            project: project, connection: DriverConnection(platform: "ios"), deviceSession: session,
            settings: settings, reportDir: reportDir, dryRun: false,
            appPath: nil, appName: nil, appBundleID: nil, registerChildProcess: nil)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: argsFile, encoding: .utf8)
            .split(separator: "\n").count, 1)
    }
}
