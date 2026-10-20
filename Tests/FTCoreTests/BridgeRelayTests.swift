// Wi-Fi の実機のブリッジへの中継(BridgeRelay)と、シナリオの子への渡し方(BridgeRelayPlan・ScenarioHost.run)。
// 実機が無くても、宛先を手元の echo サーバにすれば中継の性質は確かめられる

import Foundation
import XCTest
@testable import FTCore

final class BridgeRelayTests: XCTestCase {

    // MARK: - 中継

    /// 届いた接続を決めた宛先へつなぎ、両向きに流す。止めた後は受け付けない
    func testRelaysBothWaysToTheTargetAndStopsAcceptingAfterStop() throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        let relay = try BridgeRelay(listenPort: 0, targetHost: "127.0.0.1", targetPort: echo.port)
        XCTAssertNotEqual(relay.port, 0)
        XCTAssertEqual(try Self.roundTrip(port: relay.port, payload: "ping"), "ping")
        XCTAssertEqual(try Self.roundTrip(port: relay.port, payload: "second"), "second", "2本目の接続を中継しない")
        relay.stop()
        XCTAssertThrowsError(try Self.roundTrip(port: relay.port, payload: "x"), "止めた後も受け付けた")
    }

    /// stop() を呼ばずに手放しても閉じる(受付のスレッドが中継を強く握ると、deinit の後始末が永久に走らない)
    func testReleasingTheRelayClosesIt() throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        var relay: BridgeRelay? = try BridgeRelay(listenPort: 0, targetHost: "127.0.0.1", targetPort: echo.port)
        let port = try XCTUnwrap(relay?.port)
        XCTAssertEqual(try Self.roundTrip(port: port, payload: "a"), "a")
        weak let released = relay
        relay = nil
        XCTAssertNil(released, "手放した中継が解放されない")
        XCTAssertThrowsError(try Self.roundTrip(port: port, payload: "b"), "手放した後も受け付けた")
    }

    /// 待ち受けのポートを指定できる(実機と同じ番号で立てる = 子が台帳からトークンを引けるようにする)
    func testListensOnTheRequestedPortAndDoesNotShareIt() throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        let wanted = try Self.freePort()
        let relay = try BridgeRelay(listenPort: wanted, targetHost: "127.0.0.1", targetPort: echo.port)
        defer { relay.stop() }
        XCTAssertEqual(relay.port, wanted)
        XCTAssertEqual(try Self.roundTrip(port: wanted, payload: "abc"), "abc")
        // 同じ番号の2つ目は立たない(SO_REUSEPORT を付けていない = 別の待ち受けと番号を共有しない)
        XCTAssertThrowsError(try BridgeRelay(listenPort: wanted, targetHost: "127.0.0.1", targetPort: echo.port))
    }

    // MARK: - 子への渡し方

    /// LAN の先のブリッジだけを中継する。子の宛先は 127.0.0.1・ポートは実機と同じ番号
    func testPlanRelaysOnlyNonLoopbackBridgesOutsideDryRun() {
        let lan = DriverConnection(platform: "ios", port: 8123, udid: "U", xcuiPort: 8124, physical: true,
                                   host: "192.168.1.20")
        let planned = BridgeRelayPlan.plan(lan, dryRun: false)
        XCTAssertEqual(planned.child.host, "127.0.0.1")
        XCTAssertEqual(planned.child.port, 8123)
        XCTAssertEqual(planned.child.xcuiPort, 8124)
        XCTAssertEqual(planned.child.udid, "U")
        XCTAssertTrue(planned.child.physical)
        XCTAssertEqual(planned.relays.map(\.port), [8123, 8124])
        XCTAssertEqual(Set(planned.relays.map(\.host)), ["192.168.1.20"])

        for connection in [DriverConnection(platform: "ios", port: 8123, xcuiPort: 8124),
                           DriverConnection(platform: "ios", port: 8123, host: "127.0.0.1")] {
            let untouched = BridgeRelayPlan.plan(connection, dryRun: false)
            XCTAssertEqual(untouched.child.host, connection.host)
            XCTAssertTrue(untouched.relays.isEmpty)
        }
        XCTAssertTrue(BridgeRelayPlan.plan(lan, dryRun: true).relays.isEmpty, "dry-run はデバイスに触らない")
        let samePort = DriverConnection(platform: "ios", port: 8123, xcuiPort: 8123, host: "192.168.1.20")
        XCTAssertEqual(BridgeRelayPlan.plan(samePort, dryRun: false).relays.map(\.port), [8123])
    }

    // MARK: - 補助

    static func roundTrip(port: UInt16, payload: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let bytes = Array(payload.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { throw POSIXError(.ECONNRESET) }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    static func freePort() throws -> UInt16 {
        let probe = try BridgeRelay(listenPort: 0, targetHost: "127.0.0.1", targetPort: 9)
        let port = probe.port
        probe.stop()
        return port
    }
}

/// 受けたものをそのまま返す(1接続1往復)
private final class EchoServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = UInt16(bigEndian: actual.sin_port)
        fd = listener
        Thread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                Thread {
                    var buffer = [UInt8](repeating: 0, count: 256)
                    let count = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
                    if count > 0 { _ = buffer.withUnsafeBytes { write(client, $0.baseAddress, count) } }
                    close(client)
                }.start()
            }
        }.start()
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

/// ScenarioHost.run の配線: LAN の先のブリッジは、子へは `--bridge-host 127.0.0.1` と実機と同じポートで渡り、
/// 子が動いている間だけ中継が開いている(子の終了後は閉じる)
final class ScenarioHostBridgeRelayTests: XCTestCase {
    private var savedPackageRoot: String?
    private var root: URL!

    override func setUpWithError() throws {
        savedPackageRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-bridge-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let savedPackageRoot { setenv("FT_PACKAGE_ROOT", savedPackageRoot, 1) } else { unsetenv("FT_PACKAGE_ROOT") }
        try? FileManager.default.removeItem(at: root)
    }

    func testChildReachesTheBridgeOnlyThroughTheRelayWhileItRuns() async throws {
        try "// swift-tools-version: 6.0".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let project = TestProject(name: "Relay", rootURL: root.appendingPathComponent("TestProjects/Relay"))
        let path = root.appendingPathComponent(".build/debug").appendingPathComponent(project.productName)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let port = try BridgeRelayTests.freePort()
        let argsFile = root.appendingPathComponent("reports/args.txt").path
        let reachFile = root.appendingPathComponent("reports/reach.txt").path
        let script = """
        #!/bin/sh
        read first
        printf '%s\\n' "$*" > '\(argsFile)'
        if /usr/bin/nc -z -G 2 127.0.0.1 \(port); then echo reachable > '\(reachFile)'; else echo refused > '\(reachFile)'; fi
        echo '{"kind":"scenarioFinished","passed":true}'
        """
        try (script + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        setenv("FT_PACKAGE_ROOT", root.path, 1)

        // 192.0.2.1 は文書用の届かないアドレス(中継の待ち受けまでで十分 = 子からの接続は受けられる)
        let connection = DriverConnection(platform: "ios", port: port, udid: "00008110-000000000000001E",
                                          physical: true, host: "192.0.2.1")
        let passed = await ScenarioHost.run(
            project: project, scenarioID: "Relay.S0010", connection: connection,
            deviceSession: RunDeviceSession(), classHasBeforeAll: false, scenarioTimeoutOverride: nil,
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports").path) { _ in }
        XCTAssertTrue(passed)
        let args = try String(contentsOfFile: argsFile, encoding: .utf8)
        XCTAssertTrue(args.contains("--bridge-host 127.0.0.1"), args)
        XCTAssertFalse(args.contains("192.0.2.1"), "子へ実機の IP を渡した: \(args)")
        XCTAssertTrue(args.contains("--port \(port) "), args)
        XCTAssertEqual(try String(contentsOfFile: reachFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "reachable", "子の間に中継へ繋げない")
        XCTAssertThrowsError(try BridgeRelayTests.roundTrip(port: port, payload: "x"), "子の終了後も中継が開いている")
    }
}
