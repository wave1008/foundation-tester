// 用途 `.script` の枠を、文字列の形ではなく **実際に `sandbox-exec` へ掛けた結果**で確かめる
// (理由は ScenarioSandboxTests の冒頭と同じ)。

import XCTest
@testable import FTCore

final class ScriptSandboxTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-script-sandbox-\(UUID().uuidString)", isDirectory: true)
        for sub in ["workspace/scripts", "workspace/data", "reports", "repo/.fleetest/hooks", "home/.ssh",
                    "home/.config/fleetest/secrets", "extra", "temp"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data("secret".utf8).write(to: root.appendingPathComponent("home/.ssh/id"))
        try Data("plain".utf8).write(to: root.appendingPathComponent("home/readable"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("home/.config/fleetest/config.json"))
        try Data("token".utf8).write(to: root.appendingPathComponent("home/.config/fleetest/secrets/p.env"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ sub: String) -> String { root.appendingPathComponent(sub).path }

    private func scriptScope(ports: [UInt16] = []) -> ScenarioSandbox.Scope {
        var scope = ScenarioSandbox.Scope(
            purpose: .script, reportDir: path("reports"),
            denyRead: [path("home/.ssh"), path("home/.config")],
            projectRoot: path("workspace"), stateRoots: [path("repo")],
            home: path("home"), userTempRoots: [path("temp")], runnerName: "fleetest-script",
            remoteBridgePorts: [])
        scope.dataDir = path("workspace/data")
        scope.allowedLoopbackPorts = ports
        return scope
    }

    private func runSandboxedOutput(_ command: [String], scope: ScenarioSandbox.Scope,
                                    timeout: Double? = nil) throws -> Shell.Result {
        let profile = try ScenarioSandbox.profile(scope)
        let probe = try Shell.run([ScenarioSandbox.sandboxExecPath, "-p", profile, "/usr/bin/true"])
        try XCTSkipIf(probe.status != 0, "cannot apply Seatbelt here: \(probe.output)")
        let wrapped = ScenarioSandbox.wrap(
            runner: URL(fileURLWithPath: command[0]), arguments: Array(command.dropFirst()), profile: profile)
        return try Shell.run([wrapped.executable.path] + wrapped.arguments, timeout: timeout)
    }

    private func run(_ command: [String], scope: ScenarioSandbox.Scope? = nil) throws -> Int32 {
        try runSandboxedOutput(command, scope: scope ?? scriptScope()).status
    }

    private func touch(_ sub: String, scope: ScenarioSandbox.Scope? = nil) throws -> Int32 {
        try run(["/usr/bin/touch", path(sub)], scope: scope)
    }

    func testDataDirectoryContentsAreWritable() throws {
        XCTAssertEqual(try touch("workspace/data/f"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("workspace/data/f")))
        XCTAssertEqual(try run(["/bin/mkdir", path("workspace/data/sub")]), 0)
    }

    func testDataDirectoryItselfCannotBeRemoved() throws {
        XCTAssertNotEqual(try run(["/bin/rmdir", path("workspace/data")]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("workspace/data")))
    }

    func testEverythingElseIsNotWritable() throws {
        XCTAssertNotEqual(try touch("workspace/scripts/x"), 0)
        XCTAssertNotEqual(try touch("workspace/x"), 0)
        XCTAssertNotEqual(try touch("reports/x"), 0)
        XCTAssertNotEqual(try touch("repo/.fleetest/x"), 0)
        XCTAssertNotEqual(try touch("repo/.fleetest/hooks/x"), 0)
        XCTAssertNotEqual(try touch("home/x"), 0)
        XCTAssertNotEqual(try touch("home/.fleetest/x"), 0)
        XCTAssertNotEqual(try touch("extra/x"), 0)
    }

    func testHookWritablePathsAreWritable() throws {
        var scope = scriptScope()
        scope.hookWritablePaths = [path("extra")]
        XCTAssertEqual(try touch("extra/x", scope: scope), 0)
        XCTAssertNotEqual(try touch("workspace/scripts/x", scope: scope), 0)
    }

    func testScriptTemporaryRootIsWritable() throws {
        XCTAssertEqual(try touch("temp/x"), 0)
    }

    func testCredentialStoresAreUnreadableAndOrdinaryFilesAreReadable() throws {
        XCTAssertNotEqual(try run(["/bin/cat", path("home/.ssh/id")]), 0)
        XCTAssertNotEqual(try run(["/bin/cat", path("home/.config/fleetest/secrets/p.env")]), 0)
        XCTAssertEqual(try run(["/bin/cat", path("home/readable")]), 0)
        XCTAssertEqual(try run(["/bin/cat", path("home/.config/fleetest/config.json")]), 0)
    }

    private static let denied = "Operation not permitted"

    private func nc(port: UInt16) -> [String] {
        ["/usr/bin/nc", "-v", "-z", "-G", "1", "127.0.0.1", String(port)]
    }

    func testOnlyDeclaredLoopbackPortsAreReachable() throws {
        let declared = try ScriptLoopbackListener()
        let other = try ScriptLoopbackListener()
        defer { declared.close(); other.close() }
        XCTAssertEqual(try Shell.run(nc(port: other.port)).status, 0, "枠の外では繋がること")
        let open = try runSandboxedOutput(nc(port: declared.port), scope: scriptScope(ports: [declared.port]))
        XCTAssertEqual(open.status, 0, open.output)
        let closed = try runSandboxedOutput(nc(port: other.port), scope: scriptScope(ports: [declared.port]))
        XCTAssertNotEqual(closed.status, 0)
        XCTAssertTrue(closed.output.contains(Self.denied), closed.output)
        let none = try runSandboxedOutput(nc(port: declared.port), scope: scriptScope())
        XCTAssertTrue(none.output.contains(Self.denied), none.output)
    }

    /// bind が通ると nc は待ち受けたまま戻らない(`-w` は listen には効かない)。時間切れを「待ち受けできた」失敗として
    /// 扱い、テストを刺さらせない(拒否されるときの失敗は即時なので 5 秒は十分)
    func testScriptCannotListen() throws {
        do {
            let result = try runSandboxedOutput(
                ["/usr/bin/nc", "-l", "127.0.0.1", "59871", "-w", "1"], scope: scriptScope(), timeout: 5)
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains(Self.denied), result.output)
        } catch ShellError.timedOut {
            XCTFail("nc kept listening inside the script sandbox (bind was allowed)")
        }
    }

    /// **シナリオの枠も待ち受けられない**(Seatbelt の localhost は自機の全アドレスで、開けると 0.0.0.0 で待ち受けて
    /// LAN から繋いだ相手へ応答できた)。全アドレスでもループバックでも断る
    func testScenarioCannotListenEither() throws {
        var scenario = scriptScope()
        scenario.purpose = .scenario
        for address in ["0.0.0.0", "127.0.0.1"] {
            do {
                let result = try runSandboxedOutput(["/usr/bin/nc", "-l", address, "59872", "-w", "1"],
                                                    scope: scenario, timeout: 5)
                XCTAssertNotEqual(result.status, 0, "\(address): \(result.output)")
            } catch ShellError.timedOut {
                XCTFail("nc kept listening on \(address) inside the scenario sandbox (bind was allowed)")
            }
        }
    }

    func testProfileOmitsWhatOnlyScenariosNeed() throws {
        let script = try ScenarioSandbox.profile(scriptScope(ports: [8080]))
        for absent in ["iokit", "MTLCompilerService", "lsd.mapdb", "appleneuralengine", "modelmanager",
                       "localhost:*", "network-bind", "network-inbound", "file-issue-extension"] {
            XCTAssertFalse(script.contains(absent), absent)
        }
        XCTAssertTrue(script.contains("(allow network-outbound (remote ip \"localhost:8080\"))"))
        var scenarioScope = scriptScope()
        scenarioScope.purpose = .scenario
        let scenario = try ScenarioSandbox.profile(scenarioScope)
        for present in ["iokit", "MTLCompilerService", "lsd.mapdb", "appleneuralengine", "localhost:*"] {
            XCTAssertTrue(scenario.contains(present), present)
        }
        // シナリオも待ち受けは開けない(Seatbelt の localhost は自機の全アドレス = LAN から繋げた)
        for absent in ["network-bind", "network-inbound"] {
            XCTAssertFalse(scenario.contains(absent), absent)
        }
    }

    func testScriptWritableSetHoldsOnlyTheDeclaredPlaces() {
        var scope = scriptScope()
        scope.hookWritablePaths = ["/h"]
        scope.extraWritable = ["/e"]
        XCTAssertEqual(ScenarioSandbox.writablePaths(scope), [path("workspace/data"), "/h", path("temp"), "/e"])
        XCTAssertEqual(try ScenarioSandbox.childWritableRegexes(scope, containerUDID: nil), [])
    }
}

private final class ScriptLoopbackListener {
    let port: UInt16
    private let descriptor: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = 0
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
