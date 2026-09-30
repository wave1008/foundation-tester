// `SimctlPolicy` は「親が子の代わりに実行してよい simctl の形」の唯一の定義元。ここが緩むと、
// サンドボックスの中のシナリオが Simulator(= 枠の外)で任意のコマンドを起こせる。

import XCTest
@testable import FTCore

final class SimctlPolicyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-broker-\(UUID().uuidString)", isDirectory: true)
        for sub in ["tool/InAppBridge/build", "writable/apps/Evil.app", "apps/Good.app"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("tool/InAppBridge/build/libFTInAppBridge.dylib"))
        try Data().write(to: root.appendingPathComponent("writable/evil.dylib"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func path(_ sub: String) -> String { root.appendingPathComponent(sub).path }

    private var context: SimctlPolicy.Context {
        SimctlPolicy.Context(
            udid: "UDID-1", deviceName: "iPhone A", toolRoots: [path("tool")],
            childWritableRoots: [ScenarioSandbox.canonicalPath(path("writable"))],
            childWritablePattern: "^/nonexistent-ft/Devices/[^/]+/data/")
    }

    private func refusal(_ argv: [String], context: SimctlPolicy.Context? = nil) -> String? {
        SimctlPolicy.check(argv, context: context ?? self.context)?.reason
    }

    private func simctl(_ arguments: String...) -> [String] { ["xcrun", "simctl"] + arguments }

    func testTheShapesTheDriversUseAreAllowed() {
        let bridge = path("tool/InAppBridge/build/libFTInAppBridge.dylib")
        let allowed: [[String]] = [
            simctl("list", "devices", "-j"),
            simctl("list", "-j", "devicetypes", "devices"),
            simctl("listapps", "UDID-1"),
            simctl("bootstatus", "UDID-1", "-b"),
            simctl("terminate", "UDID-1", "com.example.app"),
            simctl("uninstall", "UDID-1", "com.example.app"),
            simctl("get_app_container", "UDID-1", "com.example.app"),
            simctl("get_app_container", "UDID-1", "com.example.app", "data"),
            simctl("get_app_container", "iPhone A", "com.example.app", "app"),
            simctl("privacy", "UDID-1", "reset", "all", "com.example.app"),
            simctl("openurl", "UDID-1", "myapp://x?y=1"),
            simctl("install", "UDID-1", path("apps/Good.app")),
            simctl("launch", "--terminate-running-process", "UDID-1", "com.example.app"),
            simctl("launch", "UDID-1", "com.example.app"),
            simctl("spawn", "UDID-1", "launchctl", "list"),
            simctl("spawn", "UDID-1", "launchctl", "kickstart", "-k", "system/com.apple.cfprefsd.xpc.daemon"),
            ["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=\(bridge)", "SIMCTL_CHILD_FT_PORT=8135",
             "SIMCTL_CHILD_FT_OWNER_REPO=/x", "SIMCTL_CHILD_FT_WEBVIEW_DOM=0"]
                + simctl("launch", "--terminate-running-process", "UDID-1", "com.example.app"),
        ]
        for argv in allowed {
            XCTAssertNil(refusal(argv), argv.joined(separator: " "))
        }
    }

    /// `simctl spawn` は Simulator の中 = 枠の外で任意のコマンドを起こす口。固定の2形以外は全部断る
    func testSpawnOfAnythingElseIsRefused() {
        XCTAssertNotNil(refusal(simctl("spawn", "UDID-1", "defaults", "write", "/tmp/x", "k", "v")))
        XCTAssertNotNil(refusal(simctl("spawn", "UDID-1", "launchctl", "list", "extra")))
        XCTAssertNotNil(refusal(simctl("spawn", "UDID-1", "launchctl", "kickstart", "-k", "system/other")))
        XCTAssertNotNil(refusal(simctl("spawn", "UDID-1", "/bin/sh", "-c", "touch /tmp/x")))
        XCTAssertNotNil(refusal(simctl("spawn", "UDID-1")))
    }

    func testVerbsOutsideTheListAreRefused() {
        for verb in ["erase", "delete", "boot", "shutdown", "addmedia", "push", "keychain", "io",
                     "pbcopy", "ui", "status_bar", "create", "clone", "diagnose", "location"] {
            XCTAssertNotNil(refusal(simctl(verb, "UDID-1")), verb)
        }
        XCTAssertNotNil(refusal(["xcrun", "devicectl", "list"]))
        XCTAssertNotNil(refusal(["/bin/sh", "-c", "xcrun simctl list"]))
    }

    func testAnotherDeviceIsRefusedWhenTheLaneDeviceIsKnown() {
        XCTAssertNotNil(refusal(simctl("terminate", "UDID-2", "com.example.app")))
        XCTAssertNotNil(refusal(simctl("launch", "booted", "com.example.app")))
        XCTAssertNotNil(refusal(simctl("spawn", "UDID-2", "launchctl", "list")))
        // ポートだけを指定した run は UDID が親に分からないので、デバイスは問わない
        var unknown = context
        unknown.udid = nil
        XCTAssertNil(refusal(simctl("terminate", "UDID-2", "com.example.app"), context: unknown))
    }

    /// 子が書ける場所のアプリを入れさせない(枠の中で作った実行物を Simulator = 枠の外で動かせる)
    func testInstallFromAChildWritableLocationIsRefused() {
        XCTAssertNotNil(refusal(simctl("install", "UDID-1", path("writable/apps/Evil.app"))))
        XCTAssertNotNil(refusal(simctl("install", "UDID-1", "/nonexistent-ft/Devices/UDID-9/data/Evil.app")))
        // symlink 越しでも実体で判定する
        let link = root.appendingPathComponent("link.app")
        try? FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("writable/apps/Evil.app"))
        XCTAssertNotNil(refusal(simctl("install", "UDID-1", link.path)))
    }

    /// 起動するアプリへ渡せる環境変数は決まった4つだけで、注入できるのはツール本体のブリッジだけ
    func testLaunchEnvironmentIsRestrictedToTheBridgeInjection() {
        let launch = simctl("launch", "--terminate-running-process", "UDID-1", "com.example.app")
        XCTAssertNotNil(refusal(["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=\(path("writable/evil.dylib"))"] + launch))
        XCTAssertNotNil(refusal(["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/usr/lib/libz.dylib"] + launch))
        let bridge = path("tool/InAppBridge/build/libFTInAppBridge.dylib")
        XCTAssertNotNil(refusal(["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=\(bridge):\(path("writable/evil.dylib"))"] + launch))
        XCTAssertNotNil(refusal(["SIMCTL_CHILD_DYLD_LIBRARY_PATH=\(path("writable"))"] + launch))
        XCTAssertNotNil(refusal(["DYLD_INSERT_LIBRARIES=\(bridge)"] + launch), "接頭辞なし = simctl 自身へ効く")
        XCTAssertNotNil(refusal(["PATH=/tmp"] + simctl("listapps", "UDID-1")), "launch 以外は環境変数を受けない")
        XCTAssertNotNil(refusal(launch + ["--extra-argument"]))
    }

    func testBundleIDShape() {
        XCTAssertTrue(SimctlPolicy.isBundleID("com.example.my-app_2"))
        XCTAssertFalse(SimctlPolicy.isBundleID(""))
        XCTAssertFalse(SimctlPolicy.isBundleID("--help"))
        XCTAssertFalse(SimctlPolicy.isBundleID("com.example.app;ls"))
        XCTAssertFalse(SimctlPolicy.isBundleID("com example"))
    }

    func testSplitSeparatesTheLeadingEnvironmentFromTheSimctlCall() throws {
        let parts = try XCTUnwrap(SimctlPolicy.split(["A=1", "B=x=y", "xcrun", "simctl", "launch", "D", "b"]))
        XCTAssertEqual(parts.environment, ["A": "1", "B": "x=y"])
        XCTAssertEqual(parts.simctl, ["launch", "D", "b"])
        XCTAssertNil(SimctlPolicy.split(["adb", "devices"]))
        XCTAssertNil(SimctlPolicy.split(["xcrun", "simctl"]))
        XCTAssertNil(SimctlPolicy.split(["xcrun", "devicectl", "list"]))
    }
}

/// 親の broker と子の gateway を、実際の unix ソケット越しに往復させる
final class SandboxBrokerRoundTripTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        func record(_ argv: [String]) { lock.lock(); calls.append(argv); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private func makeBroker(_ recorder: Recorder) throws -> SandboxBroker {
        try SandboxBroker(
            context: SimctlPolicy.Context(udid: "UDID-1", deviceName: nil, toolRoots: [], childWritableRoots: []),
            directory: NSTemporaryDirectory(),
            execute: { argv, _, stdin in
                recorder.record(argv)
                return (7, Data("ran:".utf8) + (stdin ?? Data()))
            })
    }

    func testAllowedCallIsExecutedByTheParentAndItsResultComesBack() throws {
        let recorder = Recorder()
        let broker = try makeBroker(recorder)
        defer { broker.stop() }
        let argv = ["xcrun", "simctl", "terminate", "UDID-1", "com.example.app"]
        let result = try XCTUnwrap(SandboxGateway.forward(
            argv, timeout: 3, stdin: Data([0x00, 0xFF, 0x0A]), socketPath: broker.socketPath))
        XCTAssertEqual(result.0, 7)
        XCTAssertEqual(result.1, Data("ran:".utf8) + Data([0x00, 0xFF, 0x0A]))
        XCTAssertEqual(recorder.all, [argv])
    }

    func testRefusedCallIsNotExecutedAndTheReasonComesBack() throws {
        let recorder = Recorder()
        let broker = try makeBroker(recorder)
        defer { broker.stop() }
        let result = try XCTUnwrap(SandboxGateway.forward(
            ["xcrun", "simctl", "spawn", "UDID-1", "/bin/sh", "-c", "id"], timeout: nil, stdin: nil,
            socketPath: broker.socketPath))
        XCTAssertEqual(result.0, SandboxGateway.refusedStatus)
        XCTAssertTrue(String(decoding: result.1, as: UTF8.self).contains("sandbox: refused"))
        XCTAssertEqual(recorder.all, [])
    }

    /// simctl 以外は素通し(nil)。broker へは何も送らない
    func testNonSimctlCommandsAreNotForwarded() throws {
        let recorder = Recorder()
        let broker = try makeBroker(recorder)
        defer { broker.stop() }
        XCTAssertNil(SandboxGateway.forward(["adb", "devices"], timeout: nil, stdin: nil, socketPath: broker.socketPath))
        XCTAssertEqual(recorder.all, [])
    }

    /// broker が居ないときは simctl を**自分で実行しに行かず**失敗を返す(枠の中では繋げないので、
    /// 素通しすると CoreSimulator の接続エラーになり原因が読めない)
    func testUnreachableBrokerFailsInsteadOfFallingThrough() throws {
        let result = try XCTUnwrap(SandboxGateway.forward(
            ["xcrun", "simctl", "listapps", "UDID-1"], timeout: nil, stdin: nil,
            socketPath: NSTemporaryDirectory() + "ftb-missing.sock"))
        XCTAssertEqual(result.0, SandboxGateway.refusedStatus)
        XCTAssertTrue(String(decoding: result.1, as: UTF8.self).contains("cannot reach the fleetest broker"))
    }

    func testStopRemovesTheSocket() throws {
        let broker = try makeBroker(Recorder())
        XCTAssertTrue(FileManager.default.fileExists(atPath: broker.socketPath))
        broker.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: broker.socketPath))
    }

    /// 枠の外(`FT_SANDBOX_BROKER` が無い)では `Shell.run` は何も転送しない
    func testShellRunIsUntouchedOutsideTheSandbox() throws {
        XCTAssertNil(ProcessInfo.processInfo.environment[SandboxGateway.environmentKey])
        XCTAssertNil(SandboxGateway.intercept(["xcrun", "simctl", "listapps", "UDID-1"], timeout: nil, stdin: nil))
    }
}
