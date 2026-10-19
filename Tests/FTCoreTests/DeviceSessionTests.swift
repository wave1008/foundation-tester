// RunDeviceSession(デバイスごとの setUpDevice の済み印・run 全体のメモと beforeAll)と DeviceSessionHandoff の単体テスト。
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

    /// 起動してよいときの写し(断られたら nil)
    private static func launch(_ session: RunDeviceSession, _ className: String,
                        beforeAll: Bool = false) async -> DeviceSessionHandoff? {
        if case .launch(let handoff) = await session.handoff(className: className, classHasBeforeAll: beforeAll) {
            return handoff
        }
        return nil
    }

    func testFirstHandoffRunsSetUpDeviceAndCarriesMemo() async {
        let session = RunDeviceSession()
        let handoff = await Self.launch(session, "Login")
        XCTAssertEqual(handoff?.runSetUpDevice, true)
        XCTAssertEqual(handoff?.runBeforeAll, false, "beforeAll を持たないクラスに受け持たせた")
        XCTAssertEqual(handoff?.memo, [:])
        XCTAssertEqual(handoff?.cmd, "deviceSession")
    }

    func testPassedSetUpIsNotRunAgain() async {
        let session = RunDeviceSession()
        XCTAssertTrue(session.apply(event("deviceSetUp", status: "began"), className: "Login"))
        XCTAssertTrue(session.apply(event("deviceSetUp", status: "passed"), className: "Login"))
        session.scenarioEnded(className: "Login")
        let handoff = await Self.launch(session, "Login")
        XCTAssertEqual(handoff?.runSetUpDevice, false)
    }

    func testFailedSetUpBlocksTheClass() async {
        let session = RunDeviceSession()
        session.apply(event("deviceSetUp", status: "began"), className: "Login")
        session.apply(event("deviceSetUp", status: "failed"), className: "Login")
        let decision = await session.handoff(className: "Login", classHasBeforeAll: false)
        XCTAssertEqual(decision, .setUpDeviceFailed)
    }

    func testBeganWithoutOutcomeBecomesFailedAtScenarioEnd() async {
        let session = RunDeviceSession()
        session.apply(event("deviceSetUp", status: "began"), className: "Login")
        session.scenarioEnded(className: "Login")
        let decision = await session.handoff(className: "Login", classHasBeforeAll: false)
        XCTAssertEqual(decision, .setUpDeviceFailed)
    }

    func testNotAttemptedClassKeepsRunningSetUpAfterScenarioEnded() async {
        let session = RunDeviceSession()
        session.scenarioEnded(className: "Plain")
        let handoff = await Self.launch(session, "Plain")
        XCTAssertEqual(handoff?.runSetUpDevice, true)
    }

    func testClassesAreIndependent() async {
        let session = RunDeviceSession()
        session.apply(event("deviceSetUp", status: "failed"), className: "A")
        session.apply(event("deviceSetUp", status: "passed"), className: "B")
        let a = await Self.launch(session, "A")
        let b = await Self.launch(session, "B")
        let c = await Self.launch(session, "C")
        XCTAssertNil(a)
        XCTAssertEqual(b?.runSetUpDevice, false)
        XCTAssertEqual(c?.runSetUpDevice, true)
    }

    func testMemoKeepsWriteOrderAndClearEmptiesAll() async {
        let session = RunDeviceSession()
        XCTAssertTrue(session.apply(event("memoWrite", key: "user", value: "a"), className: "X"))
        session.apply(event("memoWrite", key: "user", value: "b"), className: "X")
        session.apply(event("memoWrite", key: "other", value: "z"), className: "X")
        session.apply(event("memoWrite", key: nil, value: "ignored"), className: "X")
        session.apply(event("memoWrite", key: "k", value: nil), className: "X")
        let written = await Self.launch(session, "Y")
        XCTAssertEqual(written?.memo, ["user": ["a", "b"], "other": ["z"]])
        XCTAssertTrue(session.apply(event("memoClear"), className: "X"))
        let cleared = await Self.launch(session, "Y")
        XCTAssertEqual(cleared?.memo, [:])
    }

    // MARK: - run 全体の共有(メモ・beforeAll)

    /// **メモは run 全体で1つ**(ユーザー決定)。別のデバイスで書いた値が、次に起動するシナリオに届く。
    /// setUpDevice の済み印はデバイスごとのまま
    func testMemoIsSharedAcrossDevicesButSetUpDeviceIsNot() async {
        let book = RunDeviceSessionBook()
        let iphone = book.session(for: "iPhone-01")
        let pixel = book.session(for: "Pixel-01")
        iphone.apply(event("memoWrite", key: "token", value: "abc"), className: "Login")
        iphone.apply(event("deviceSetUp", status: "passed"), className: "Login")
        let onPixel = await Self.launch(pixel, "Login")
        XCTAssertEqual(onPixel?.memo, ["token": ["abc"]], "別のデバイスで書いたメモが見えない")
        XCTAssertEqual(onPixel?.runSetUpDevice, true, "setUpDevice の済み印がデバイスをまたいだ")
        pixel.apply(event("memoClear"), className: "Login")
        let afterClear = await Self.launch(iphone, "Login")
        XCTAssertEqual(afterClear?.memo, [:])
    }

    /// beforeAll は run × クラスで1回。受け持ったデバイスが終えるまで、別のデバイスはそのクラスを起動しない
    func testBeforeAllRunsOnceAndOtherDevicesWaitForIt() async {
        let book = RunDeviceSessionBook()
        let first = book.session(for: "iPhone-01")
        let second = book.session(for: "iPhone-02")
        let owner = await Self.launch(first, "Login", beforeAll: true)
        XCTAssertEqual(owner?.runBeforeAll, true)

        let waiting = Task { await Self.launch(second, "Login", beforeAll: true) }
        // 受け持った側が始めて終えるまで、待つ側は返らない
        first.apply(event("beforeAll", status: "began"), className: "Login")
        try? await Task.sleep(for: .milliseconds(100))
        first.apply(event("memoWrite", key: "account", value: "u1"), className: "Login")
        first.apply(event("beforeAll", status: "passed"), className: "Login")
        let afterwards = await waiting.value
        XCTAssertEqual(afterwards?.runBeforeAll, false, "beforeAll が2回走る")
        XCTAssertEqual(afterwards?.memo, ["account": ["u1"]], "beforeAll で書いたメモが届かない")
        first.scenarioEnded(className: "Login")
        let later = await Self.launch(first, "Login", beforeAll: true)
        XCTAssertEqual(later?.runBeforeAll, false)
    }

    /// 始めたまま終わった(途中で死んだ)beforeAll は撃ち直さず、このクラスの残りを走らせない
    func testBeforeAllThatBeganButNeverFinishedFailsTheClass() async {
        let book = RunDeviceSessionBook()
        let first = book.session(for: "iPhone-01")
        let second = book.session(for: "iPhone-02")
        _ = await Self.launch(first, "Login", beforeAll: true)
        let waiting = Task { await second.handoff(className: "Login", classHasBeforeAll: true) }
        first.apply(event("beforeAll", status: "began"), className: "Login")
        first.scenarioEnded(className: "Login")
        let decision = await waiting.value
        XCTAssertEqual(decision, .beforeAllFailed)
    }

    /// 受け持ったのに始めずに終わった(子を起こせなかった・beforeAll の前で落ちた)なら、待っていた側が受け持ち直す
    func testBeforeAllThatNeverBeganIsTakenOverByAWaitingDevice() async {
        let book = RunDeviceSessionBook()
        let first = book.session(for: "iPhone-01")
        let second = book.session(for: "iPhone-02")
        _ = await Self.launch(first, "Login", beforeAll: true)
        let waiting = Task { await Self.launch(second, "Login", beforeAll: true) }
        try? await Task.sleep(for: .milliseconds(50))
        first.scenarioEnded(className: "Login")
        let takenOver = await waiting.value
        XCTAssertEqual(takenOver?.runBeforeAll, true)
    }

    /// beforeAll を持たないクラスは待たない(他のクラスの受け持ちに引きずられない)
    func testClassWithoutBeforeAllDoesNotWait() async {
        let book = RunDeviceSessionBook()
        _ = await Self.launch(book.session(for: "iPhone-01"), "Login", beforeAll: true)
        let other = await Self.launch(book.session(for: "iPhone-02"), "Cart", beforeAll: false)
        XCTAssertEqual(other?.runBeforeAll, false)
        let sameClassNoHook = await Self.launch(book.session(for: "iPhone-03"), "Login", beforeAll: false)
        XCTAssertNotNil(sameClassNoHook)
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
        let original = DeviceSessionHandoff(memo: ["k": ["1", "2"]], runSetUpDevice: true, runBeforeAll: true)
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
                       DeviceSessionHandoff(memo: ["k": ["v"]], runSetUpDevice: false, runBeforeAll: false))
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
            classHasBeforeAll: false,
            scenarioTimeoutOverride: nil,
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports").path) { sink.append($0) }

        XCTAssertTrue(passed)
        let first = try String(contentsOfFile: received, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(DeviceSessionHandoff.decode(line: first),
                       DeviceSessionHandoff(memo: [:], runSetUpDevice: true, runBeforeAll: false))
        XCTAssertFalse(sink.events.contains { ["memoWrite", "memoClear", "deviceSetUp"].contains($0.kind) })
        let next = await session.handoff(className: "Login", classHasBeforeAll: false)
        XCTAssertEqual(next, .launch(DeviceSessionHandoff(memo: ["token": ["abc"]], runSetUpDevice: false,
                                                          runBeforeAll: false)))
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
            classHasBeforeAll: false,
            scenarioTimeoutOverride: nil,
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

    /// afterAll は run の最後に、申告したクラスだけを専用の子(`--after-all-only`)で1回だけ走らせる。
    /// 走らせる先は、そのクラスのシナリオが走った OS で選ぶ。選べなければ走らせず「走らなかった」と言う
    func testAfterAllRunsOnceInAnAfterAllOnlyChildOnADeviceOfTheDeclaringPlatform() async throws {
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let project = TestProject(name: "SessionAfterAll",
                                  rootURL: root.appendingPathComponent("TestProjects/SessionAfterAll"))
        let path = root.appendingPathComponent(".build/debug").appendingPathComponent(project.productName)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let argsFile = root.appendingPathComponent("reports/args.txt").path
        let script = """
        #!/bin/sh
        read first
        printf '%s\\n' "$*" >> '\(argsFile)'
        echo '{"kind":"scenarioFinished","passed":true,"reportPath":"/tmp/a.md"}'
        """
        try (script + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        setenv("FT_PACKAGE_ROOT", root.path, 1)

        let book = RunDeviceSessionBook()
        var declared = ScenarioEvent(kind: "afterAll")
        declared.status = "declared"
        XCTAssertTrue(book.session(for: "Pixel-01").apply(declared, className: "Cart", platform: "android"))
        book.session(for: "iPhone-01").apply(declared, className: "Login", platform: "ios")
        let settings = ScenarioExecutionSettings(fm: FMConfig(enabled: false))
        let reportDir = root.appendingPathComponent("reports").path
        var asked: [Set<String>] = []
        let outcomes = await ScenarioHost.runAfterAlls(
            project: project, shared: book.shared,
            target: { platforms in
                asked.append(platforms)
                // Android のデバイスは残っていない形
                guard platforms.contains("ios") else { return nil }
                return ScenarioHost.LifecycleTarget(connection: DriverConnection(platform: "ios"),
                                                    appPath: nil, appName: nil, appBundleID: nil)
            },
            settings: settings, reportDir: reportDir, dryRun: false, registerChildProcess: nil)
        XCTAssertEqual(asked, [["android"], ["ios"]], "申告順・申告した OS で選んでいない")
        XCTAssertEqual(outcomes.map(\.className), ["Cart", "Login"])
        XCTAssertEqual(outcomes.map(\.ran), [false, true])
        XCTAssertEqual(outcomes.last?.passed, true)
        XCTAssertTrue(ScenarioHost.describe(outcomes[0]).contains("afterAll of Cart was not run"),
                      ScenarioHost.describe(outcomes[0]))
        let args = try String(contentsOfFile: argsFile, encoding: .utf8)
        XCTAssertTrue(args.contains("--scenario Login "), args)
        XCTAssertTrue(args.contains("--after-all-only"), args)
        XCTAssertFalse(args.contains("--device-teardown-only"), args)
        // 2回目は走らせない(run × クラスで1回)
        let again = await ScenarioHost.runAfterAlls(
            project: project, shared: book.shared, target: { _ in nil },
            settings: settings, reportDir: reportDir, dryRun: false, registerChildProcess: nil)
        XCTAssertTrue(again.isEmpty)
    }
}
