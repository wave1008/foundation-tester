// ScenarioSandbox のプロファイルを、文字列の形ではなく **実際に `sandbox-exec` へ掛けた結果**で確かめる。
// Seatbelt の書式は公式に文書化されていないので、文字列だけを見るテストは「書式としては正しいが
// 1つも当たらない規則」を通す(実際に `/var` と `/private/var` の食い違いでそうなる)。

import XCTest
@testable import FTCore

final class ScenarioSandboxTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        // 日本語と空白を含める(プロジェクト名・デバイス名がそのままパスに入る)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-sandbox-テスト \(UUID().uuidString)", isDirectory: true)
        let container = "home/Library/Developer/CoreSimulator/Devices/UDID-1/data/Containers"
        for sub in ["reports", "project/.fleetest", "repo/.fleetest/hooks", "tool/.fleetest/hooks",
                    "stills", "home/.ssh", "home/.config/fleetest", "home/.config/gh",
                    "home/Library/Caches/fleetest", "outside",
                    container + "/Data/Application/APP-1/Library", container + "/Bundle/Application/APP-1"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data("secret".utf8).write(to: root.appendingPathComponent("home/.ssh/id"))
        try Data("plain".utf8).write(to: root.appendingPathComponent("home/readable"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("home/.config/fleetest/config.json"))
        try Data("token".utf8).write(to: root.appendingPathComponent("home/.config/gh/hosts.yml"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ sub: String) -> String { root.appendingPathComponent(sub).path }

    /// 一時領域そのものは書ける場所に入れない(`root` がその下にあり、入れると全部が通る)
    private func scope(remoteBridgePorts: [UInt16] = []) -> ScenarioSandbox.Scope {
        var scope = ScenarioSandbox.Scope(
            reportDir: path("reports"), denyRead: [path("home/.ssh"), path("home/.config")],
            projectRoot: path("project"), stateRoots: [path("repo"), path("tool")],
            home: path("home"), userTempRoots: [], runnerName: "fleetest-scenarios-X",
            remoteBridgePorts: remoteBridgePorts)
        scope.extraWritable = [path("stills")]
        return scope
    }

    /// 枠の中でコマンドを実行して終了コードを返す。枠を掛けられない環境(このテスト自体が
    /// 別の Seatbelt の中で走っている)では skip する
    private func runSandboxed(_ command: [String], scope: ScenarioSandbox.Scope? = nil) throws -> Int32 {
        try runSandboxedOutput(command, scope: scope).status
    }

    private func runSandboxedOutput(_ command: [String],
                                    scope: ScenarioSandbox.Scope? = nil) throws -> Shell.Result {
        let profile = try ScenarioSandbox.profile(scope ?? self.scope())
        let probe = try Shell.run([ScenarioSandbox.sandboxExecPath, "-p", profile, "/usr/bin/true"])
        try XCTSkipIf(probe.status != 0, "cannot apply Seatbelt here: \(probe.output)")
        let wrapped = ScenarioSandbox.wrap(
            runner: URL(fileURLWithPath: command[0]), arguments: Array(command.dropFirst()),
            profile: profile)
        return try Shell.run([wrapped.executable.path] + wrapped.arguments)
    }

    private func touch(_ sub: String) throws -> Int32 {
        try runSandboxed(["/usr/bin/touch", path(sub)])
    }

    func testWritesInsideTheAllowedRootsSucceed() throws {
        XCTAssertEqual(try touch("reports/a"), 0)
        XCTAssertEqual(try touch("project/.fleetest/a"), 0)
        XCTAssertEqual(try touch("repo/.fleetest/a"), 0)
        XCTAssertEqual(try touch("tool/.fleetest/a"), 0)
        XCTAssertEqual(try touch("stills/a"), 0)
        XCTAssertEqual(try touch("home/Library/Caches/fleetest/fm.lock.0"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("reports/a")))
    }

    func testWritesOutsideTheAllowedRootsAreDenied() throws {
        XCTAssertNotEqual(try touch("outside/a"), 0)
        XCTAssertNotEqual(try touch("project/a"), 0)
        XCTAssertNotEqual(try touch("repo/a"), 0)
        XCTAssertNotEqual(try touch("home/a"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("outside/a")))
    }

    /// `.fleetest` は書けるが、次の run が読んで teardown を枠の外で実行する `hooks/` は書けない
    func testHooksDirectoryStaysReadOnlyInsideTheWritableStateDirectory() throws {
        XCTAssertNotEqual(try touch("repo/.fleetest/hooks/1.json"), 0)
        XCTAssertNotEqual(try touch("tool/.fleetest/hooks/1.json"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("repo/.fleetest/hooks/1.json")))
    }

    /// `clearAppData` は Simulator のデータコンテナの中身を直接消す。開けるのはデータ側だけで、
    /// アプリ本体(Bundle)と、コンテナの外の Simulator のファイルは開けない
    func testSimulatorDataContainerIsWritableButTheRestOfTheSimulatorIsNot() throws {
        let device = "home/Library/Developer/CoreSimulator/Devices/UDID-1/data"
        XCTAssertEqual(try runSandboxed(
            ["/bin/rmdir", path(device + "/Containers/Data/Application/APP-1/Library")]), 0)
        XCTAssertNotEqual(try touch(device + "/Containers/Bundle/Application/APP-1/a"), 0)
        XCTAssertNotEqual(try touch(device + "/a"), 0)
    }

    func testStateRootsCollectThePackageTheCheckoutTheOverrideAndTheExecutableAncestor() throws {
        for sub in ["work/.build/checkouts/tool-a/Runner", "work/.build/checkouts/other",
                    "override/Runner", "clone/Runner", "clone/.build/debug", "not-a-tool"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for sub in ["work/.build/checkouts/tool-a/Runner/project.yml", "clone/Runner/project.yml",
                    "override/Runner/project.yml"] {
            try Data().write(to: root.appendingPathComponent(sub))
        }
        let roots = ScenarioSandbox.stateRoots(
            packageRoot: root.appendingPathComponent("work"),
            environment: ["FT_TOOL_ROOT": path("override")],
            executable: root.appendingPathComponent("clone/.build/debug/fleetest"))
        let real = ScenarioSandbox.canonicalPath(root.path)
        XCTAssertEqual(roots, ["work", "work/.build/checkouts/tool-a", "override", "clone"]
            .map { real + "/" + $0 })
        // `FT_TOOL_ROOT` はツール本体の目印があるときだけ採る(任意の場所の `.fleetest` を書けるようにさせない)
        XCTAssertFalse(ScenarioSandbox.stateRoots(
            packageRoot: nil, environment: ["FT_TOOL_ROOT": path("not-a-tool")], executable: nil)
            .contains(real + "/not-a-tool"))
        // clone 構成(パッケージ = ツール本体)では1つに畳まれる
        XCTAssertEqual(ScenarioSandbox.stateRoots(
            packageRoot: root.appendingPathComponent("clone"), environment: [:],
            executable: root.appendingPathComponent("clone/.build/debug/fleetest")), [real + "/clone"])
    }

    /// 全拒否が土台なので、名指しで開けていない mach サービスには繋げない。CoreSimulator に繋げると
    /// `simctl spawn` で枠の外にプロセスを起こせる(だから Simulator の操作は親の broker が代行する)
    func testCoreSimulatorIsUnreachableFromInsideTheSandbox() throws {
        let outside = try Shell.run(["xcrun", "simctl", "list", "devices", "-j"])
        try XCTSkipIf(outside.status != 0, "simctl is not usable on this machine")
        XCTAssertNotEqual(try runSandboxed(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"]), 0)
    }

    /// adb サーバと Emulator のコンソール / adbd は閉じる(開いていると `adb shell` で Emulator の中 = 枠の外から
    /// 外部へ出られる)。規則は localhost:* の許可より後に置く(後に書いた規則が勝つ)
    func testAdbServerAndEmulatorPortsAreDeniedAfterTheLocalhostAllowance() throws {
        let profile = try ScenarioSandbox.profile(scope())
        let allow = try XCTUnwrap(profile.range(of: "(allow network-outbound (remote ip \"localhost:*\"))"))
        for port in [UInt16(5037), 5554, 5555, 5585] {
            let deny = try XCTUnwrap(profile.range(of: "(deny network-outbound (remote ip \"localhost:\(port)\"))"),
                                     "port \(port) is not denied")
            XCTAssertLessThan(allow.lowerBound, deny.lowerBound, "port \(port)")
        }
        XCTAssertEqual(ScenarioSandbox.deniedLoopbackPorts(environment: ["ANDROID_ADB_SERVER_PORT": "6037"]).first, 6037)
        let plan = try XCTUnwrap(try ScenarioSandbox.plan(settings: .init(), home: "/H"))
        XCTAssertFalse(plan.allowDirectAdb)
        for name in [".android", ".emulator_console_auth_token"] {
            XCTAssertTrue(plan.denyRead.contains("/H/" + name), name)
        }
    }

    /// マシン側の `allowDirectAdb` だけが adb を開ける: ポートの拒否と adb の鍵の読み取り拒否を外す
    func testAllowDirectAdbOpensTheAdbPortsAndKeys() throws {
        let plan = try XCTUnwrap(try ScenarioSandbox.plan(settings: .init(allowDirectAdb: true), home: "/H"))
        XCTAssertTrue(plan.allowDirectAdb)
        XCTAssertFalse(plan.denyRead.contains("/H/.android"))
        XCTAssertTrue(plan.denyRead.contains("/H/.ssh"), "他の読み取り拒否はそのまま")
        var open = scope()
        open.allowDirectAdb = true
        let profile = try ScenarioSandbox.profile(open)
        XCTAssertFalse(profile.contains("(deny network-outbound (remote ip \"localhost:5037\"))"))
        XCTAssertTrue(profile.contains("(deny network*)"), "外部への通信は閉じたまま")
        let url = root.appendingPathComponent("config.json")
        try Data(#"{"sandbox":{"allowDirectAdb":true}}"#.utf8).write(to: url)
        XCTAssertEqual(try ScenarioSandbox.machineSettings(url: url).allowDirectAdb, true)
    }

    func testAllowDirectAdbLetsTheSandboxReachAnEmulatorPort() throws {
        let emulator: LoopbackListener
        do { emulator = try LoopbackListener(port: 5585) } catch {
            throw XCTSkip("port 5585 is in use on this machine (an Emulator may hold it)")
        }
        defer { emulator.close() }
        var open = scope()
        open.allowDirectAdb = true
        XCTAssertEqual(try runSandboxed(["/usr/bin/nc", "-z", "-G", "2", "127.0.0.1", "5585"], scope: open), 0)
    }

    /// 規則が本当に効くこと: 一時ポートの待受には繋がり(陽性対照)、Emulator のポートには繋がらない
    func testConnectingToAnEmulatorPortFailsInsideTheSandbox() throws {
        let open = try LoopbackListener(port: 0)
        defer { open.close() }
        let emulator: LoopbackListener
        do { emulator = try LoopbackListener(port: 5585) } catch {
            throw XCTSkip("port 5585 is in use on this machine (an Emulator may hold it)")
        }
        defer { emulator.close() }
        XCTAssertEqual(try runSandboxed(["/usr/bin/nc", "-z", "-G", "2", "127.0.0.1", String(open.port)]), 0,
                       "陽性対照: localhost の一時ポートに繋がらない")
        XCTAssertNotEqual(try runSandboxed(["/usr/bin/nc", "-z", "-G", "2", "127.0.0.1", "5585"]), 0)
    }

    func testTheBaseIsDenyDefault() throws {
        let profile = try ScenarioSandbox.profile(scope())
        XCTAssertTrue(profile.hasPrefix("(version 1)\n(deny default)\n"), profile)
        XCTAssertFalse(profile.contains("(allow default)"))
        XCTAssertFalse(profile.contains("CoreSimulator.CoreSimulatorService"))
        // LaunchServices は読み取り専用の写像だけ(Create ML の UTType 判定)。アプリの起動と登録の口は閉じたまま
        XCTAssertTrue(profile.contains("(global-name \"com.apple.lsd.mapdb\")"))
        XCTAssertFalse(profile.contains("com.apple.CoreServices.coreservicesd"))
        XCTAssertFalse(profile.contains("com.apple.lsd.modifydb"))
        // 名前の無い unix ソケット全般は開けない(開けると Docker のソケット等に届く)
        XCTAssertFalse(profile.contains("(remote unix-socket))"))
    }

    /// 親の broker のソケットは、名指ししたときだけ繋がる
    func testBrokerSocketIsReachableOnlyWhenDeclared() throws {
        let recorder = NSLock()
        let broker = try SandboxBroker(
            context: SimctlPolicy.Context(udid: nil, deviceName: nil, toolRoots: [], childWritableRoots: []),
            directory: NSTemporaryDirectory(), execute: { _, _, _ in recorder.lock(); recorder.unlock(); return (0, Data()) })
        defer { broker.stop() }
        // curl は繋げなければ 7 で終わる。繋がれば broker の(HTTP でない)応答を読んで別のコードで終わる
        let probe = ["/usr/bin/curl", "-s", "-m", "3", "--unix-socket", broker.socketPath, "http://broker/"]
        let cannotConnect: Int32 = 7
        XCTAssertNotEqual(try Shell.run(probe).status, cannotConnect, "枠の外では繋がること")
        // unix ソケットへ繋ぐにはそのパスへの書き込みも要る。ソケットは一時領域に置くので、
        // 一時領域を書ける状態にしたうえで「名指しの有無」だけを変える
        var undeclared = scope()
        undeclared.userTempRoots = [NSTemporaryDirectory()]
        XCTAssertEqual(try runSandboxed(probe, scope: undeclared), cannotConnect)
        var declared = undeclared
        declared.brokerSocket = broker.socketPath
        XCTAssertNotEqual(try runSandboxed(probe, scope: declared), cannotConnect)
    }

    /// 画像判定の補助プロセスのソケットも、名指ししたときだけ繋がる(閉じたままだと Vision の異常を救えない)
    func testHelperSocketIsReachableOnlyWhenDeclared() throws {
        let listener = try SandboxBroker(
            context: SimctlPolicy.Context(udid: nil, deviceName: nil, toolRoots: [], childWritableRoots: []),
            directory: NSTemporaryDirectory(), execute: { _, _, _ in (0, Data()) })
        defer { listener.stop() }
        let probe = ["/usr/bin/curl", "-s", "-m", "3", "--unix-socket", listener.socketPath, "http://helper/"]
        let cannotConnect: Int32 = 7
        var undeclared = scope()
        undeclared.userTempRoots = [NSTemporaryDirectory()]
        XCTAssertEqual(try runSandboxed(probe, scope: undeclared), cannotConnect)
        var declared = undeclared
        declared.helperSockets = [listener.socketPath]
        XCTAssertNotEqual(try runSandboxed(probe, scope: declared), cannotConnect)
    }

    /// レポートを書かない起動(一覧取得・暖機)は出力先を持たない
    func testScopeWithoutAReportDirectoryStillBuilds() throws {
        var scope = self.scope()
        scope.reportDir = nil
        XCTAssertNotEqual(try runSandboxed(["/usr/bin/touch", path("reports/a")], scope: scope), 0)
        XCTAssertEqual(try runSandboxed(["/usr/bin/touch", path("project/.fleetest/a")], scope: scope), 0)
    }

    /// まだ無いレポート出力先でも規則が当たる。**作れるのは出力先そのものから下だけ**で、途中の親は
    /// 作れない(だから `ScenarioHost` が起動前に作っておく)
    func testNotYetExistingReportDirectoryIsWritableButItsMissingParentsAreNot() throws {
        var scope = self.scope()
        scope.reportDir = path("reports/new")
        XCTAssertEqual(try runSandboxed(["/bin/mkdir", path("reports/new")], scope: scope), 0)
        XCTAssertEqual(try runSandboxed(["/usr/bin/touch", path("reports/new/a")], scope: scope), 0)
        scope.reportDir = path("outside/x/y")
        XCTAssertNotEqual(try runSandboxed(["/bin/mkdir", "-p", path("outside/x/y")], scope: scope), 0)
    }

    func testSecretLocationsAreUnreadableAndOtherFilesAreReadable() throws {
        XCTAssertNotEqual(try runSandboxed(["/bin/cat", path("home/.ssh/id")]), 0)
        XCTAssertNotEqual(try runSandboxed(["/bin/cat", path("home/.config/gh/hosts.yml")]), 0)
        XCTAssertEqual(try runSandboxed(["/bin/cat", path("home/readable")]), 0)
    }

    /// `~/.config` は閉じるが、子が FM の並列枠を読む `~/.config/fleetest` だけは開け直す
    /// (後に書いた規則が勝つ)。**書けはしない**(書ければ枠を外す `disabled` を子が立てられる)
    func testFleetestConfigIsReadableButNotWritableInsideTheClosedConfigDirectory() throws {
        XCTAssertEqual(try runSandboxed(["/bin/cat", path("home/.config/fleetest/config.json")]), 0)
        XCTAssertNotEqual(try touch("home/.config/fleetest/config.json"), 0)
    }

    /// 書く場所を差し替える環境変数は、書ける場所の中を指すときだけ通す(足す形にすると、環境変数だけで
    /// 任意の場所を書けるようにできる)
    func testRedirectedDirectoriesMustStayInsideTheWritableLocations() throws {
        let inside = ["FT_OCCLUSION_DUMP_DIR": path("project/.fleetest/dump")]
        XCTAssertNoThrow(try ScenarioSandbox.checkRedirects(scope(), environment: inside))
        let outside = ["FT_OCR_COMPILE_DIR": path("home/Library/LaunchAgents")]
        XCTAssertThrowsError(try ScenarioSandbox.checkRedirects(scope(), environment: outside)) { error in
            XCTAssertEqual(error as? ScenarioSandbox.ConfigError,
                           .redirectOutsideSandbox(key: "FT_OCR_COMPILE_DIR", path: path("home/Library/LaunchAgents")))
        }
        // 書ける場所の名前を前方一致で含むだけの兄弟は外(`reports-evil` は `reports` の中ではない)
        XCTAssertThrowsError(try ScenarioSandbox.checkRedirects(
            scope(), environment: ["FT_FM_USAGE_DIR": path("reports-evil")]))
        XCTAssertNoThrow(try ScenarioSandbox.checkRedirects(scope(), environment: ["FT_FM_USAGE_DIR": ""]))
    }

    /// localhost は通り、外は通らない。外の宛先は文書用のアドレス(192.0.2.1 = どこにも届かない)で、
    /// **拒否と到達不能を文言で分ける** —— 枠が断れば connect が即 EPERM、断らなければ時間切れになる
    /// (ネットワークに出られない環境でも結果が変わらない)
    func testOnlyLoopbackIsReachable() throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        XCTAssertEqual(try runSandboxedOutput(nc(host: "127.0.0.1", port: listener.port)).status, 0)
        let outside = try Shell.run(nc(host: Self.unroutable, port: 9))
        XCTAssertFalse(outside.output.contains(Self.denied), outside.output)
        let inside = try runSandboxedOutput(nc(host: Self.unroutable, port: 9))
        XCTAssertTrue(inside.output.contains(Self.denied), inside.output)
    }

    /// localhost に居ないブリッジ(実機を LAN 越しに駆動)は、そのポートだけ開く
    func testRemoteBridgePortIsReachableOnlyWhenDeclared() throws {
        let declared = try runSandboxedOutput(
            nc(host: Self.unroutable, port: 9), scope: scope(remoteBridgePorts: [9]))
        XCTAssertFalse(declared.output.contains(Self.denied), declared.output)
        let other = try runSandboxedOutput(
            nc(host: Self.unroutable, port: 9), scope: scope(remoteBridgePorts: [10]))
        XCTAssertTrue(other.output.contains(Self.denied), other.output)
    }

    private static let unroutable = "192.0.2.1"
    private static let denied = "Operation not permitted"

    private func nc(host: String, port: UInt16) -> [String] {
        ["/usr/bin/nc", "-v", "-z", "-G", "1", host, String(port)]
    }

    func testRemoteBridgePortsComeOnlyFromNonLoopbackHosts() {
        let local = DriverConnection(platform: "ios", port: 8123, xcuiPort: 8124)
        XCTAssertEqual(ScenarioSandbox.remoteBridgePorts(local), [])
        let loopback = DriverConnection(platform: "ios", port: 8123, xcuiPort: 8124, host: "127.0.0.1")
        XCTAssertEqual(ScenarioSandbox.remoteBridgePorts(loopback), [])
        let lan = DriverConnection(platform: "ios", port: 8123, xcuiPort: 8124, host: "192.168.1.20")
        XCTAssertEqual(ScenarioSandbox.remoteBridgePorts(lan), [8123, 8124])
    }

    func testCanonicalPathResolvesSymlinksForPathsThatDoNotExistYet() throws {
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("outside"))
        let resolved = ScenarioSandbox.canonicalPath(link.appendingPathComponent("not/yet").path)
        let realRoot = try XCTUnwrap(realpath(root.path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        XCTAssertEqual(resolved, realRoot + "/outside/not/yet")
        // 一時領域は /var → /private/var の symlink の下にある
        XCTAssertTrue(resolved.hasPrefix("/private/"), resolved)
    }

    func testPathWithQuoteAndBackslashIsEscapedAndControlCharacterIsRefused() throws {
        let quoted = try ScenarioSandbox.subpath("/nonexistent-ft/a\"b\\c")
        XCTAssertEqual(quoted, "(subpath \"/nonexistent-ft/a\\\"b\\\\c\")")
        XCTAssertThrowsError(try ScenarioSandbox.subpath("/nonexistent-ft/a\nb")) { error in
            XCTAssertEqual(error as? ScenarioSandbox.ProfileError,
                           .unrepresentablePath("/nonexistent-ft/a\nb"))
        }
    }

    /// 引用符を含むパスの規則が**書式として通り、かつ当たる**こと(エスケープを誤ると枠ごと掛からない)
    func testQuotedPathRuleAppliesForReal() throws {
        let odd = root.appendingPathComponent("odd \"dir\"")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        var scope = self.scope()
        scope.reportDir = odd.path
        XCTAssertEqual(
            try runSandboxed(["/usr/bin/touch", odd.appendingPathComponent("a").path], scope: scope), 0)
        XCTAssertNotEqual(try runSandboxed(["/usr/bin/touch", path("outside/b")], scope: scope), 0)
    }

    func testWrapPutsTheProfileAndRunnerBeforeTheOriginalArguments() {
        let wrapped = ScenarioSandbox.wrap(
            runner: URL(fileURLWithPath: "/x/runner"), arguments: ["run", "--json"], profile: "P")
        XCTAssertEqual(wrapped.executable.path, "/usr/bin/sandbox-exec")
        XCTAssertEqual(wrapped.arguments, ["-p", "P", "/x/runner", "run", "--json"])
    }
}

/// 全アドレスで待ち受けるだけの TCP ソケット(接続は受け取らない。`nc -z` は接続の成立だけを見る)
private final class LoopbackListener {
    let port: UInt16
    private let descriptor: Int32

    /// port 0 は空きポート
    init(port requested: UInt16 = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = requested.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        descriptor = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    func close() { Darwin.close(descriptor) }
}

