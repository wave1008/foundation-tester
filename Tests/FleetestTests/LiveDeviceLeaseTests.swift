// ライブ操作のデバイスの印(LiveDeviceLease)が MCPDeviceLease と同じファイル・鍵で読み書きすること
// (実地 B5: 書いていなかったので DeviceBooter 等の門がライブ操作中のデバイスを無言で止めていた)。
// 判定・警告文そのものは Tests/FleetestMCPTests/MCPDeviceLeaseTests.swift が固定するので、
// ここは「LiveDeviceLease が同じ場所へ委譲しているか」だけを見る。

import XCTest
import FTBridgeClient
@testable import fleetest

final class LiveDeviceLeaseTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LiveDeviceLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    /// refresh は MCPDeviceLease.holderPID から読める同じ印を書くこと(DeviceBooter 等の
    /// 読み手はここしか見ないので、別の場所・別の書式へ書くと届かない)。見ているだけ(acting: false)でも数える
    func testRefreshIsVisibleThroughMCPDeviceLease() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let lease = LiveDeviceLease(stateDir: stateDir, key: "UDID-LIVE", pid: pid, log: { _ in })
        lease.refresh(acting: false)
        XCTAssertEqual(MCPDeviceLease.holderPID(stateDir: stateDir, key: "UDID-LIVE", excluding: []), pid)
    }

    /// release() は自分の印だけを消すこと(他プロセスの印は残る)
    func testReleaseRemovesOnlyOwnLease() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let lease = LiveDeviceLease(stateDir: stateDir, key: "UDID-LIVE", pid: pid, log: { _ in })
        lease.refresh(acting: false)
        // launchd(1) は必ず生きているので「他プロセスの印」の陽性対照に使える(MCPDeviceLeaseTests と同じ手法)
        MCPDeviceLease.write(stateDir: stateDir, key: "UDID-OTHER", pid: 1)
        lease.release()
        XCTAssertNil(MCPDeviceLease.holderPID(stateDir: stateDir, key: "UDID-LIVE", excluding: []),
                     "release() は自分の印を消すこと")
        XCTAssertEqual(MCPDeviceLease.holderPID(stateDir: stateDir, key: "UDID-OTHER", excluding: []), 1,
                       "release() は他プロセスの印を消さないこと")
    }

    /// run(RunLease)が同じデバイスを持っていれば、既存の警告文をそのまま返すこと(新しい文言を作らない)
    func testRefreshWarnsWhenARunHoldsTheSameDevice() {
        RunLease.write(stateDir: stateDir, key: "UDID-LIVE", pid: 1)
        var logged: [String] = []
        let lease = LiveDeviceLease(stateDir: stateDir, key: "UDID-LIVE",
                                    pid: ProcessInfo.processInfo.processIdentifier,
                                    log: { logged.append($0) })
        lease.refresh(acting: false)
        XCTAssertTrue(logged.contains { $0.contains("a fleetest run (pid 1) is using this device right now") },
                      "\(logged)")
    }

    /// 観測だけのコマンドは操作に数えない(MCP への警告の根拠になるので、取り違えると見ているだけで警告が戻る)
    func testOnlyRefreshAndFrameAreObservationOnly() {
        func command(_ cmd: String, raw: [String: Any] = [:]) -> ApiLiveServeCommand {
            ApiLiveServeCommand(cmd: cmd, raw: raw.merging(["cmd": cmd]) { a, _ in a })
        }
        XCTAssertFalse(command("refresh").drivesDevice)
        XCTAssertFalse(command("frame").drivesDevice)
        XCTAssertTrue(command("tap").drivesDevice)
        XCTAssertTrue(command("launch").drivesDevice)
        XCTAssertFalse(command("tap", raw: ["ref": "abc"]).drivesDevice,
                       "型違いの行は perform を撃たない")
    }
}
