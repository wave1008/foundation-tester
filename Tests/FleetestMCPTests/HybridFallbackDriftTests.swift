// maintainer-notes §51.2(2026-09-25): inapp モード(in-app ブリッジ + XCUITest ブリッジ)のキャッシュ命中は主(in-app)の udid だけを確かめており、
// `HybridFallbackDriver` の fallback(AppAttachDriver)が握る XCUITest ポートは無検査のまま
// キャッシュから返っていた。ブリッジは run のたびに起動し直されるので、そのポートは別デバイスへ
// (あるいは同じデバイスの in-app ブリッジへ)移り得る —— home/drag/座標 press/gesture/pinch は
// すべて fallback 経由なので、黙って別の機へ操作が届く。
//
// maintainer-notes §51.10(2026-09-25): 同じ穴が主(primary)ポートにもある。`deviceIdentityChanged` は udid しか見ず、
// ref を使う呼び出し(`usesRememberedDeviceState`)にしか効かないので、ref を使わない
// `ft_terminate` のような呼び出しでは効かせようがない。同じ udid のまま run のたびの起動し直しで
// ブリッジ(xcuitest ⇄ inapp)だけが入れ替わった形を見逃し、その bridge には無い操作
// (in-app には /terminate が無い)を撃って 501、逆向きなら別の ref 体系へ黙って撃つ。
//
// 判定そのもの(`FTCore.BridgeIdentityCheck.hybridFallbackDrift`)と probe の配線
// (`FTBridgeClient.HybridFallbackIdentity.drifted`)は MCP とライブ操作(api live serve)の
// 共有部品なので、それぞれ Tests/FTCoreTests・Tests/FTBridgeClientTests 側で固定する。
// ここで見るのは **MCP のキャッシュ配線**(記録・no-op・後始末・両経路での呼び出し・
// `primaryBridgeOutcome` の拒否/黙って作り直し/**differentDevice はrefの有無を問わず拒否**の振り分け)だけ。

import XCTest
@testable import fleetest_mcp
import FTCore

final class HybridFallbackDriftTests: XCTestCase {

    private let key = "direct:ios:8123:"

    // MARK: - I/O 込みの入口。材料が欠けていれば撃たずに false(不明を「変わった」と読まない)

    /// fallback ポートを覚えていない(inapp モードではない、または未記録)ときは撃たずに false
    func testHybridFallbackDriftedIsNoOpWithoutARecordedFallbackPort() async {
        let server = MCPServer()
        server.udids[key] = "SIM-1"

        let drifted = await server.hybridFallbackDrifted(key)

        XCTAssertFalse(drifted, "材料が無いのに判定を撃った")
    }

    /// 主の udid を覚えていない(inapp モードでない経路の使い回しキー等)ときも撃たずに false
    func testHybridFallbackDriftedIsNoOpWithoutARecordedUDID() async {
        let server = MCPServer()
        server.hybridFallbackPorts[key] = 8129

        let drifted = await server.hybridFallbackDrifted(key)

        XCTAssertFalse(drifted, "udid が無いのに判定を撃った")
    }

    /// maintainer-notes §51.10: primary の port/udid/bridge のどれかが無ければ撃たずに .none
    /// (`connectedPorts`/`udids`/`bridges` は Android のキーには揃わないので、
    /// この no-op が Android の呼び出しを毎回 probe しないことも兼ねて守る)
    func testPrimaryBridgeDriftIsNoOpWithoutAllThreeOfPortUDIDBridge() async {
        let server = MCPServer()
        server.connectedPorts[key] = 8123
        server.udids[key] = "SIM-1"
        // bridges[key] を書かない

        let drift = await server.primaryBridgeDrift(key)

        XCTAssertEqual(drift, .none, "bridge を覚えていないのに判定を撃った")
    }

    // MARK: - forgetDeviceState が新しい記憶も捨てること(DeviceStateInvalidationTests の汎用走査と対)

    func testForgetDeviceStateDropsTheFallbackPort() {
        let server = MCPServer()
        server.hybridFallbackPorts[key] = 8129

        server.forgetDeviceState(key)

        XCTAssertNil(server.hybridFallbackPorts[key], "機が変わっても前の fallback ポートが残った")
    }

    // MARK: - primaryBridgeOutcome(maintainer-notes §51.10。純粋関数): drift していなければ現状維持、
    // sameDeviceBridgeChanged は「記憶に依る呼び出しだけ拒否・依らなければ黙って作り直し」、
    // differentDevice は ref の有無を問わず常に拒否

    func testPrimaryBridgeOutcomeIsUnchangedWithoutDrift() {
        let outcome = MCPServer.primaryBridgeOutcome(
            drift: .none, usesRememberedDeviceState: true, port: 8123, expectedBridge: "xcuitest",
            expectedUDID: "SIM-1", callerNamedUDID: false)
        XCTAssertEqual(outcome, .unchanged)
    }

    /// **本命**: ref を使わない呼び出し(`ft_terminate` の実測)は同じ機のブリッジだけが
    /// 変わっていても黙って作り直させる —— 拒否して「撮り直せ」と言う理由が無い
    /// (その call 自身が新しいドライバで正しく処理される)
    func testPrimaryBridgeOutcomeRebuildsSilentlyWhenTheCallDoesNotUseRememberedState() {
        let outcome = MCPServer.primaryBridgeOutcome(
            drift: .sameDeviceBridgeChanged, usesRememberedDeviceState: false, port: 8123,
            expectedBridge: "xcuitest", expectedUDID: "SIM-1", callerNamedUDID: false)
        XCTAssertEqual(outcome, .rebuildSilently)
    }

    /// ref を使う呼び出しは同じ機のブリッジの入れ替わりだけでも拒否する(ref は旧ブリッジのものなので無効)
    func testPrimaryBridgeOutcomeRefusesWhenTheCallUsesRememberedState() {
        let outcome = MCPServer.primaryBridgeOutcome(
            drift: .sameDeviceBridgeChanged, usesRememberedDeviceState: true, port: 8123,
            expectedBridge: "xcuitest", expectedUDID: "SIM-1", callerNamedUDID: false)
        guard case .refuse(let message) = outcome else {
            return XCTFail("記憶に依る呼び出しは拒否のはず: \(outcome)")
        }
        XCTAssertTrue(message.contains("8123"), message)
        XCTAssertTrue(message.contains("xcuitest"), message)
        XCTAssertTrue(message.contains("ft_snapshot"), message)
    }

    /// **本題**: ポートの中身が別のデバイスに替わった(differentDevice)なら、ref を使わない
    /// 呼び出しでも黙って作り直さず断る —— 別の実体を黙って操作し続けさせない
    func testPrimaryBridgeOutcomeRefusesDifferentDeviceEvenWithoutRememberedState() {
        let outcome = MCPServer.primaryBridgeOutcome(
            drift: .differentDevice, usesRememberedDeviceState: false, port: 8123,
            expectedBridge: "xcuitest", expectedUDID: "SIM-1", callerNamedUDID: false)
        guard case .refuse(let message) = outcome else {
            return XCTFail("別の台に替わっていたら ref の有無を問わず拒否のはず: \(outcome)")
        }
        XCTAssertTrue(message.contains("8123"), message)
        XCTAssertTrue(message.contains("SIM-1"), message)
    }

    /// ref を使う呼び出しも同様に differentDevice で拒否する
    func testPrimaryBridgeOutcomeRefusesDifferentDeviceWithRememberedState() {
        let outcome = MCPServer.primaryBridgeOutcome(
            drift: .differentDevice, usesRememberedDeviceState: true, port: 8123,
            expectedBridge: "xcuitest", expectedUDID: "SIM-1", callerNamedUDID: false)
        guard case .refuse = outcome else {
            return XCTFail("別の台に替わっていたら拒否のはず: \(outcome)")
        }
    }

    /// 呼び手が udid を明示したら(記憶の補完は port しか書かない)今そのポートのデバイスへの同意なので作り直す。
    /// これが無いと断り続けて抜けられない
    func testPrimaryBridgeOutcomeRebuildsDifferentDeviceWhenTheCallerNamedAUDID() {
        let outcome = MCPServer.primaryBridgeOutcome(
            drift: .differentDevice, usesRememberedDeviceState: false, port: 8123,
            expectedBridge: "xcuitest", expectedUDID: "SIM-1", callerNamedUDID: true)
        XCTAssertEqual(outcome, .rebuildSilently)
    }

    // MARK: - primaryBridgeCheck(I/O 込みの入口): 材料が無ければ .unchanged で、
    // forgetDeviceState は呼ばない(既存の記憶を無用に捨てない)

    func testPrimaryBridgeCheckIsUnchangedAndKeepsStateWithoutMaterial() async {
        let server = MCPServer()
        server.hybridFallbackPorts[key] = 8129  // primaryBridgeDrift には無関係の記憶が残っていること

        let outcome = await server.primaryBridgeCheck(key, args: [:])

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(server.hybridFallbackPorts[key], 8129, "材料が無いのに forgetDeviceState を呼んだ")
    }

    // MARK: - 配線: 両方のキャッシュ命中(profile 経路・直接ポート経路)が確認を呼ぶこと
    // (DeviceStateInvalidationTests.testEveryDriverCacheHitVerifiesDeviceIdentity と対)

    func testEveryDriverCacheHitAlsoChecksThePrimaryBridgeAndTheHybridFallback() throws {
        let source = try String(contentsOf: Self.driverSourceURL(), encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hits = 0
        for (index, line) in lines.enumerated() where line.contains("if let cached = drivers[key]") {
            hits += 1
            let window = lines[index..<min(index + 30, lines.count)].joined(separator: "\n")
            XCTAssertTrue(window.contains("primaryBridgeCheck"),
                          "\(index + 1) 行目のキャッシュ命中がブリッジの入れ替わりを"
                          + "確かめていない —— maintainer-notes §51.10 と同じ穴(udid だけ・ref を使う呼び出しだけ)が残る")
            XCTAssertTrue(window.contains("hybridFallbackDrifted"),
                          "\(index + 1) 行目のキャッシュ命中が inapp モードの fallback ポートを"
                          + "確かめていない —— maintainer-notes §51.2 と同じ穴(fallback だけ無検査)が残る")
        }
        XCTAssertEqual(hits, 2, "キャッシュ命中の箇所数が変わった(実測 \(hits))。増えたなら確認も入れる")
    }

    /// **両経路とも fallback ポートを記録していること**(`testBothPathsRecordWhatTheIdentityGuardNeeds`
    /// と同じ理由): 記録し忘れると `hybridFallbackDrifted` が材料無しで常に no-op になる
    func testBothPathsRecordTheHybridFallbackPort() throws {
        let source = try String(contentsOf: Self.driverSourceURL(), encoding: .utf8)
        // MCP の iOS は XCUITest だけなので、両経路とも予備ポートを消す(前の機の値を残さない)
        XCTAssertTrue(source.contains("hybridFallbackPorts[key] = nil   // MCP の iOS は XCUITest だけ(前の機の予備ポートを残さない)"),
                      "profile 経路が inapp モードの予備ポートを消していない")
        XCTAssertTrue(source.contains("hybridFallbackPorts[key] = nil   // MCP の iOS は XCUITest だけ(inapp モードの予備ポートは無い)"),
                      "直接ポート経路が inapp モードの予備ポートを消していない")
    }

    private static func driverSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Driver.swift")
    }
}
