// `ScenarioHost.run(registerChildProcess:)` は起動できた子プロセスを呼び出し側へ渡し、
// 関数が終わるまでに必ず解除(unregister)する契約。
// 呼び出し側(ApiRunCommand/ProfileRunner/Fleetest の RunInterruptState)はこの登録簿を使って
// SIGINT/SIGTERM 受信時に「いま動いているシナリオ子」を SIGTERM する。ここでは配線だけを検証する
// (実際の中断経路は fleetest ターゲット側 = InterruptRelayTests / RunInterruptStateTests)。
//
// FT_PACKAGE_ROOT で runnerURL の探索先を一時ディレクトリへ向ける
// (ScenarioHostRunnerUnavailableTests と同じ口)。

import XCTest
@testable import FTCore

private let testFMSettings = FMSettingsRecord(
    fm: true, heal: false, falsePositiveCheck: false, screenLooksLike: true, triage: true,
    ocr: true, ocrFalsePositiveCheck: true)

final class ScenarioHostRegisterChildProcessTests: XCTestCase {

    private var savedPackageRoot: String?
    private var root: URL!

    override func setUpWithError() throws {
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-register-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let savedPackageRoot { setenv("FT_PACKAGE_ROOT", savedPackageRoot, 1) } else { unsetenv("FT_PACKAGE_ROOT") }
        try? FileManager.default.removeItem(at: root)
    }

    private final class Registration: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var callCount = 0
        private(set) var unregisterCallCount = 0
        private(set) var lastProcess: Process?

        func register(_ process: Process) -> @Sendable () -> Void {
            lock.lock()
            callCount += 1
            lastProcess = process
            lock.unlock()
            return { [weak self] in
                self?.lock.lock()
                self?.unregisterCallCount += 1
                self?.lock.unlock()
            }
        }
    }

    /// 実行できる「ランナー」を1本置く(本物の fleetest-scenarios は不要 —— 検証したいのは
    /// 「起動できた子が registerChildProcess に渡り、関数終了までに unregister される」ことだけ)。
    /// JSON を1行も出さず exit 1 するので `ScenarioHost.run` は false を返す(通常の失敗経路)
    private func writeShortLivedRunner(project: TestProject) throws {
        let path = root.appendingPathComponent(".build/debug").appendingPathComponent(project.productName)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 1\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    /// 戻すと落ちる根拠: `registerChildProcess` の呼び出し・defer での unregister を
    /// ScenarioHost.run から外すと、callCount/unregisterCallCount が 0 のまま残る
    /// (呼び出し側の中断経路が「今動いている子」を一切見つけられなくなる)
    func testRegisterChildProcessIsCalledAndUnregisteredOnCompletion() async throws {
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let project = TestProject(name: "RegisterChild",
                                  rootURL: root.appendingPathComponent("TestProjects/RegisterChild"))
        try writeShortLivedRunner(project: project)
        setenv("FT_PACKAGE_ROOT", root.path, 1)

        let registration = Registration()
        let recorder = RunRecorder.begin(project: project, profile: nil, trigger: "test",
                                         captureHostMetrics: false)
        let passed = await ScenarioHost.run(
            project: project, scenarioID: "Login.S0010",
            connection: DriverConnection(platform: "ios"),
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false, heal: false)),
            reportDir: root.appendingPathComponent("reports").path,
            recording: ScenarioRecording(recorder: recorder),
            registerChildProcess: { registration.register($0) }) { _ in }
        recorder.finish(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1,
                        performanceMode: false, fmSettings: testFMSettings, setOverrides: nil)

        XCTAssertFalse(passed, "exit 1 する子は失敗として扱われる(通常の失敗経路と同じ)")
        XCTAssertEqual(registration.callCount, 1, "起動できた子は必ず1回登録される")
        XCTAssertNotNil(registration.lastProcess)
        XCTAssertEqual(registration.unregisterCallCount, 1,
                       "run() が返るまでに必ず1回だけ解除される(登録簿が肥大化しない)")
    }

    /// 起動前に失敗する経路(ランナーが見つからない)では registerChildProcess は一度も呼ばれない
    /// (子が実在しないので登録しようがない。呼び出し側が nil の子を SIGTERM しようとしない契約)
    func testRegisterChildProcessIsNotCalledWhenTheRunnerIsMissing() async throws {
        setenv("FT_PACKAGE_ROOT", root.path, 1)
        let project = TestProject(name: "NoSuchRunner-\(UUID().uuidString.prefix(8))",
                                  rootURL: root.appendingPathComponent("TestProjects/NoSuch"))
        let registration = Registration()
        let recorder = RunRecorder.begin(project: project, profile: nil, trigger: "test",
                                         captureHostMetrics: false)
        let passed = await ScenarioHost.run(
            project: project, scenarioID: "Login.S0010",
            connection: DriverConnection(platform: "ios"),
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false, heal: false)),
            reportDir: root.appendingPathComponent("reports").path,
            recording: ScenarioRecording(recorder: recorder),
            registerChildProcess: { registration.register($0) }) { _ in }
        recorder.finish(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1,
                        performanceMode: false, fmSettings: testFMSettings, setOverrides: nil)

        XCTAssertFalse(passed)
        XCTAssertEqual(registration.callCount, 0)
    }
}
