// MCP が操作している台に印を置き(run が後回しにする)、run が使用中の台なら応答の先頭で言う
// (`MCPServer.markDeviceInUse`。ユーザー決定: run は避ける・MCP は警告する = どちらも断らない)。

import XCTest
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class MCPDeviceLeaseTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!
    private var stateDir: URL!

    override func setUpWithError() throws {
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MCPDeviceLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        server.deviceLeaseStateDir = stateDir
        server.udids[MCPServer.engineKey([:])] = "UDID-X"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func snapshotText() async throws -> String {
        try await server.call(tool: "ft_snapshot", args: [:]).compactMap { $0["text"] as? String }.joined()
    }

    /// 台を指すツールを通ったら、その台の鍵で自分の pid の印を置く
    func testADeviceToolLeavesTheMCPLease() async throws {
        _ = try await snapshotText()
        XCTAssertEqual(MCPDeviceLease.liveHolders(stateDir: stateDir, excluding: []),
                       ["UDID-X": ProcessInfo.processInfo.processIdentifier])
    }

    /// **本命(逆向き)**: run の lease がある台を触ったら、その pid を名指しして言う(操作は止めない)
    func testTouchingADeviceARunHoldsIsNamed() async throws {
        RunLease.write(stateDir: stateDir, key: "UDID-X", pid: 1)
        let text = try await snapshotText()
        XCTAssertTrue(text.contains("a fleetest run (pid 1) is using this device right now"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("snapshot") }, "警告して進むこと: \(driver.calls)")
    }

    /// run が居なければ黙る
    func testNoRunLeaseStaysQuiet() async throws {
        let text = try await snapshotText()
        XCTAssertFalse(text.contains("fleetest run"), text)
    }

    /// **失敗にも言う**: run が台を使っている最中は失敗しやすい(実測: run がアプリを起こし直している間の
    /// ft_snapshot が接続拒否)。記録が無い回は引数の udid / serial で台を特定する
    func testAFailureOnADeviceARunHoldsIsNamedToo() async throws {
        RunLease.write(stateDir: stateDir, key: "SERIAL-Y", pid: 1)
        driver.failing = ["snapshot"]
        do {
            _ = try await server.call(tool: "ft_snapshot", args: ["platform": "android", "serial": "SERIAL-Y"])
            XCTFail("接続拒否は throw するはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("a fleetest run (pid 1) is using this device"),
                          error.localizedDescription)
        }
    }

    /// **別の MCP セッション**が同じ台の印を持っていたら名指しして言う(操作は止めない)。
    /// 2026-09-17 負荷テスト M16: 2本目のセッションが1本目の周回中の台を無言で操作した。
    /// 生きた別プロセスの印には launchd(1)を使う(印は開始時刻まで照合するので実在の pid が要る)
    func testTouchingADeviceAnotherMCPSessionDrivesIsNamed() async throws {
        MCPDeviceLease.write(stateDir: stateDir, key: "UDID-X", pid: 1)
        let text = try await snapshotText()
        XCTAssertTrue(text.contains("another MCP session (fleetest-mcp pid 1) is driving this device too"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("snapshot") }, "警告して進むこと: \(driver.calls)")
        XCTAssertEqual(MCPDeviceLease.liveHolders(stateDir: stateDir, excluding: []),
                       ["UDID-X": ProcessInfo.processInfo.processIdentifier], "自分の印で上書きする")
        let again = try await snapshotText()
        XCTAssertFalse(again.contains("another MCP session"), "相手が書き戻すまでは言わない: \(again)")
    }

    /// 自分の印しか無ければ黙る
    func testOwnMCPLeaseStaysQuiet() async throws {
        _ = try await snapshotText()
        let text = try await snapshotText()
        XCTAssertFalse(text.contains("another MCP session"), text)
    }
}
