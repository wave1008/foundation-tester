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

    /// simctl / devicectl / adb 以外は素通し(nil)。broker へは何も送らない
    func testNonSimctlCommandsAreNotForwarded() throws {
        let recorder = Recorder()
        let broker = try makeBroker(recorder)
        defer { broker.stop() }
        XCTAssertNil(SandboxGateway.forward(["git", "status"], timeout: nil, stdin: nil, socketPath: broker.socketPath))
        XCTAssertNil(SandboxGateway.forward(["/usr/bin/xcrun", "xcodebuild", "-version"], timeout: nil, stdin: nil,
                                            socketPath: broker.socketPath))
        XCTAssertEqual(recorder.all, [])
    }

    /// 検めたパスは実体パスに固定してから実行する。子が書ける場所の symlink を途中に挟んで検めさせ、実行の直前に
    /// 向きを変える(判定と実行の間の差し替え)と、子が作ったアプリ・ライブラリを入れさせられる
    func testCheckedPathsArePinnedToTheirRealPathsBeforeRunning() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ftb-pin-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base.appendingPathComponent("real/App.app"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("real"))
        let link = base.appendingPathComponent("link").path
        let real = ScenarioSandbox.canonicalPath(base.appendingPathComponent("real").path)
        func pinned(_ argv: [String]) -> [String] { BrokerPolicy.pinned(argv, outputDirectory: "/out").argv }

        XCTAssertEqual(pinned(["xcrun", "simctl", "install", "UDID-1", link + "/App.app"]).last, real + "/App.app")
        XCTAssertEqual(pinned(["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=" + link + "/lib.dylib", "xcrun", "simctl", "launch",
                               "UDID-1", "com.example.app"]).first,
                       "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=" + real + "/lib.dylib")
        XCTAssertEqual(pinned(["xcrun", "devicectl", "device", "install", "app", "--device", "P-1", link + "/App.app"]).last,
                       real + "/App.app")
        XCTAssertEqual(pinned(["/sdk/adb", "-s", "emulator-5554", "install", "-r", link + "/x.apk"]).last, real + "/x.apk")
        XCTAssertTrue(pinned(["bundletool", "install-apks", "--apks=" + link + "/x.apks", "--adb=/a"])
            .contains("--apks=" + real + "/x.apks"))
        // パス以外は変えない
        let terminate = ["xcrun", "simctl", "terminate", "UDID-1", "com.example.app"]
        XCTAssertEqual(pinned(terminate), terminate)
    }

    /// devicectl の出力ファイルは親が子の書ける場所へ書かない(symlink を辿らされる)。親だけの一時ファイルに書かせ、
    /// 中身を応答で返して子が自分で(= 枠の中から)書く
    func testDevicectlOutputFileIsWrittenByTheChildNotByTheParent() throws {
        let fm = FileManager.default
        let childDir = fm.temporaryDirectory.appendingPathComponent("ftb-child-\(UUID().uuidString)")
        try fm.createDirectory(at: childDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: childDir) }
        let recorder = Recorder()
        let broker = try SandboxBroker(
            context: SimctlPolicy.Context(udid: "PHONE-1", deviceName: nil, toolRoots: [],
                                          childWritableRoots: [ScenarioSandbox.canonicalPath(childDir.path)]),
            directory: NSTemporaryDirectory(),
            execute: { argv, _, _ in
                recorder.record(argv)
                if let i = argv.firstIndex(of: "--json-output") {
                    try? Data("{\"ok\":1}".utf8).write(to: URL(fileURLWithPath: argv[i + 1]))
                }
                return (0, Data())
            })
        defer { broker.stop() }
        let target = childDir.appendingPathComponent("processes.json").path
        let result = try XCTUnwrap(SandboxGateway.forward(
            ["xcrun", "devicectl", "device", "info", "processes", "--device", "PHONE-1", "--json-output", target],
            timeout: nil, stdin: nil, socketPath: broker.socketPath))
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(fm.contents(atPath: target), Data("{\"ok\":1}".utf8))
        let ran = try XCTUnwrap(recorder.all.first)
        let parentPath = ran[ran.count - 1]
        XCTAssertNotEqual(parentPath, target, "親は子のパスへ書かない")
        XCTAssertFalse(fm.fileExists(atPath: parentPath), "親の一時ファイルは片付ける")
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

/// iOS 実機の `devicectl` を親が代行するときの方針
final class DevicectlPolicyTests: XCTestCase {

    private let writable = ScenarioSandbox.canonicalPath(NSTemporaryDirectory()) + "/ft-devicectl-writable"

    private var context: SimctlPolicy.Context {
        SimctlPolicy.Context(udid: "PHONE-1", deviceName: nil, toolRoots: [], childWritableRoots: [writable])
    }

    private func refusal(_ arguments: [String]) -> String? {
        BrokerPolicy.check(["xcrun", "devicectl"] + arguments, context: context)?.reason
    }

    /// ドライバが実際に使う形(`IOSPhysical*` / `BridgeClient`)は通る
    func testTheShapesTheDriversUseAreAllowed() {
        let out = writable + "/apps.json"
        for arguments in [
            ["list", "devices", "--json-output", "-", "-q"],
            ["device", "info", "apps", "--device", "PHONE-1", "--include-all-apps", "--json-output", out],
            ["device", "info", "lockState", "--device", "PHONE-1", "--json-output", "-"],
            ["device", "info", "details", "--device", "PHONE-1", "--json-output", "-", "-q"],
            ["device", "info", "processes", "--device", "PHONE-1", "--json-output", out],
            ["device", "install", "app", "--device", "PHONE-1", "/Users/x/Build/App.app"],
            ["device", "uninstall", "app", "--device", "PHONE-1", "com.example.app"],
            ["device", "process", "openURL", "--device", "PHONE-1", "myapp://home"],
        ] {
            XCTAssertNil(refusal(arguments), arguments.joined(separator: " "))
        }
    }

    func testAnotherDeviceIsRefused() {
        XCTAssertNotNil(refusal(["device", "process", "openURL", "--device", "PHONE-2", "x://"]))
        XCTAssertNotNil(refusal(["device", "info", "lockState", "--device", "PHONE-2", "--json-output", "-"]))
    }

    /// 親に書かせる出力先は子が元々書ける場所だけ(親を使って任意の場所へ書かせない)
    func testJSONOutputOutsideTheWritableLocationsIsRefused() {
        XCTAssertNotNil(refusal(["device", "info", "processes", "--device", "PHONE-1",
                                 "--json-output", "/Users/x/Library/LaunchAgents/evil.plist"]))
    }

    /// 子が書ける場所のアプリは入れない(枠の中で作った実行物を実機で動かせる)
    func testInstallFromAChildWritableLocationIsRefused() {
        XCTAssertNotNil(refusal(["device", "install", "app", "--device", "PHONE-1", writable + "/Evil.app"]))
    }

    func testOtherVerbsAndEnvironmentAreRefused() {
        for arguments in [
            ["device", "process", "launch", "--device", "PHONE-1", "com.example.app"],
            ["device", "copy", "from", "--device", "PHONE-1"],
            ["manage", "pair", "--device", "PHONE-1"],
            ["list"],
        ] {
            XCTAssertNotNil(refusal(arguments), arguments.joined(separator: " "))
        }
        XCTAssertNotNil(BrokerPolicy.check(["A=1", "xcrun", "devicectl", "list", "devices", "--json-output", "-", "-q"],
                                           context: context))
    }

    /// 子のコードに現れる `devicectl` の呼び出しを全数拾い、方針が知っている形の頭(3語)であること。
    /// 呼び出しを足して方針に足し忘れると、サンドボックスの中の実機の run だけが落ちる(E2E は Simulator で回る)
    func testEveryDevicectlCallInTheSourcesHasAKnownShape() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let known: Set<String> = [
            "list devices --json-output", "device info apps", "device info lockState", "device info details",
            "device info processes", "device install app", "device uninstall app", "device process openURL",
        ]
        var found: [String] = []
        for module in ["FTBridgeClient", "FTCore", "FTAndroid", "FTScenarioRunner", "FTDSL"] {
            let dir = root.appendingPathComponent("Sources/\(module)")
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let regex = try NSRegularExpression(pattern: #"\["xcrun", "devicectl",\s*"([^"]+)",\s*"([^"]+)",\s*"([^"]+)""#)
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let words = (1...3).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
                    found.append(words.joined(separator: " "))
                }
            }
        }
        XCTAssertGreaterThanOrEqual(found.count, 8, "the scan did not reach the devicectl call sites")
        XCTAssertEqual(found.filter { !known.contains($0) }, [])
    }
}
