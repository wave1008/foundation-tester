// 時間のかかった呼び出しは ⏱ に段階ごとの内訳を添える(実測: 25.2 秒の ft_tap の理由が応答から読めなかった)。
// 下限は `MCPServer.elapsedBreakdownSeconds`、段階の積算は `SlowCallWatchdog`

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPElapsedBreakdownTests: XCTestCase {

    private let phases: [(phase: String, seconds: Double)] = [("running ft_tap", 1.2),
                                                              ("reading the screen after the action", 19.0)]

    func testTheBreakdownIsAddedOnlyToSlowCalls() {
        let clock = ContinuousClock()
        let slow = MCPServer.withElapsed([], since: clock.now - .seconds(20), clock: clock, breakdown: phases)
        let slowText = slow.last?["text"] as? String ?? ""
        XCTAssertTrue(slowText.contains("(running ft_tap 1.2s · reading the screen after the action 19.0s)"), slowText)
        let fast = MCPServer.withElapsed([], since: clock.now - .seconds(3), clock: clock, breakdown: phases)
        XCTAssertFalse((fast.last?["text"] as? String ?? "").contains("("))
    }

    /// 段階の積算: 入れ子を抜けても外側の段階へ足し戻す(`phaseSince` は外側の開始へ戻るので積算には使えない)
    func testPhasesAreAccumulatedAcrossNestedMarks() async throws {
        let watchdog = SlowCallWatchdog.start(callID: 990_001, tool: "ft_tap")
        defer { watchdog.finish() }
        let spent = try await MCPServer.$currentCallID.withValue(990_001) { () async throws -> [(phase: String, seconds: Double)] in
            SlowCallWatchdog.mark("outer")
            try await Task.sleep(nanoseconds: 150_000_000)
            try await SlowCallWatchdog.marking("inner") { try await Task.sleep(nanoseconds: 150_000_000) }
            try await Task.sleep(nanoseconds: 150_000_000)
            return SlowCallWatchdog.breakdown()
        }
        XCTAssertEqual(spent.map(\.phase), ["outer", "inner"])
        let outer = try XCTUnwrap(spent.first?.seconds)
        XCTAssertGreaterThanOrEqual(outer, 0.29, "入れ子の後の外側の時間が足し戻されていない: \(spent)")
    }

    /// **操作の時間を直前の「確認」の段に積まない**(計測: Android にも「probing for a system alert 9.2s」と出ていた)
    func testTheActionItselfHasItsOwnPhase() async throws {
        let driver = FakeDriver()
        var phaseAtTap: String?
        driver.onTap = {
            // mark は直前の段を返す = 撃った瞬間の段。読んだらすぐ戻す
            let previous = SlowCallWatchdog.mark("probe")
            SlowCallWatchdog.restore(previous)
            phaseAtTap = previous?.phase
        }
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        XCTAssertEqual(phaseAtTap, "performing the action")
    }

    /// **起動・データ消去は自分の段に積む**(実測: SpringBoard の確認 0.17s が、後ろの起動まで積まれて 4.7s と出た)
    func testLaunchAndClearAppDataHaveTheirOwnPhase() async throws {
        let driver = FakeDriver()
        var phases: [String] = []
        driver.onLifecycle = {
            let previous = SlowCallWatchdog.mark("probe")
            SlowCallWatchdog.restore(previous)
            if let phase = previous?.phase { phases.append(phase) }
        }
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app", "resume": true])
        _ = try await server.call(tool: "ft_clear_app_data", args: ["bundleId": "com.example.app"])
        XCTAssertEqual(phases, ["launching the app", "activating the app", "clearing the app's data"])
    }

    /// **操作の後の撮り直しは自分の段に積む**(「操作の後の読み」の中で、待ちと読みのどちらに時間を使ったか分からなかった)
    func testTheSettleReReadHasItsOwnPhase() async throws {
        let driver = FakeDriver()
        var phases: [String] = []
        driver.onSnapshot = {
            let previous = SlowCallWatchdog.mark("probe")
            SlowCallWatchdog.restore(previous)
            if let phase = previous?.phase { phases.append(phase) }
        }
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // 操作の前後で木が同じ = 木が変わって見えない → 短い待ちの後に1回撮り直す
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true])
        XCTAssertTrue(phases.contains("re-reading: the tree looked unchanged"), "\(phases)")
    }

    /// **waitForChange の安定確認は自分の段に積む**(変化を待った時間と分ける)
    func testTheChangeSettleConfirmationHasItsOwnPhase() async throws {
        let driver = FakeDriver()
        var phases: [String] = []
        driver.onSnapshot = {
            let previous = SlowCallWatchdog.mark("probe")
            SlowCallWatchdog.restore(previous)
            if let phase = previous?.phase { phases.append(phase) }
        }
        let a = driver.snapshotResponse
        var b = a
        b.elements.append(ElementInfo(ref: 99, type: "staticText", identifier: nil, label: "next", value: nil,
                                      placeholder: nil, enabled: true,
                                      frame: FTRect(x: 0, y: 700, width: 100, height: 20), depth: 1))
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [a, b, b]   // ref の確かめ → 操作の後(変わった)→ 安定確認(同じ)
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true, "waitForChange": true])
        XCTAssertTrue(phases.contains("confirming the change has settled"), "\(phases)")
    }
}
