// G6(2026-09-25): hybrid(in-app + XCUITest)キャッシュ命中は主(in-app)の udid だけを確かめており、
// `HybridFallbackDriver` の fallback(AppAttachDriver)が握る XCUITest ポートは無検査のまま
// キャッシュから返っていた。ブリッジは run のたびに建て直されるので、そのポートは別デバイスへ
// (あるいは同じデバイスの in-app ブリッジへ)移り得る —— home/drag/座標 press/gesture/pinch は
// すべて fallback 経由なので、黙って別の機へ操作が届く。
//
// G14(2026-09-25): 同じ穴が主(primary)ポートにもある。`deviceIdentityChanged` は udid しか見ず、
// ref を使う呼び出し(`usesRememberedDeviceState`)にしか効かないので、ref を使わない
// `ft_terminate` のような呼び出しでは効かせようがない。同じ udid のまま run のたびの建て直しで
// エンジン(xcuitest ⇄ inapp/hybrid)だけが入れ替わった形を見逃し、その engine には無い操作
// (in-app には /terminate が無い)を撃って 501、逆向きなら別の ref 体系へ黙って撃つ。
//
// 判定そのもの(`FTCore.BridgeIdentityCheck.hybridFallbackMismatch`)と probe の配線
// (`FTBridgeClient.HybridFallbackIdentity.drifted`)は MCP とライブ操作(api live serve)の
// 共有部品なので、それぞれ Tests/FTCoreTests・Tests/FTBridgeClientTests 側で固定する。
// ここで見るのは **MCP のキャッシュ配線**(記録・no-op・後始末・両経路での呼び出し・
// `primaryEngineOutcome` の拒否/黙って作り直しの振り分け)だけ。

import XCTest
@testable import fleetest_mcp

final class HybridFallbackDriftTests: XCTestCase {

    private let key = "direct:ios:8123:"

    // MARK: - I/O 込みの入口。材料が欠けていれば撃たずに false(不明を「変わった」と読まない)

    /// fallback ポートを覚えていない(hybrid ではない、または未記録)ときは撃たずに false
    func testHybridFallbackDriftedIsNoOpWithoutARecordedFallbackPort() async {
        let server = MCPServer()
        server.udids[key] = "SIM-1"

        let drifted = await server.hybridFallbackDrifted(key)

        XCTAssertFalse(drifted, "材料が無いのに判定を撃った")
    }

    /// 主の udid を覚えていない(hybrid でない経路の使い回しキー等)ときも撃たずに false
    func testHybridFallbackDriftedIsNoOpWithoutARecordedUDID() async {
        let server = MCPServer()
        server.hybridFallbackPorts[key] = 8129

        let drifted = await server.hybridFallbackDrifted(key)

        XCTAssertFalse(drifted, "udid が無いのに判定を撃った")
    }

    /// G14: primary の port/udid/engine のどれかが無ければ撃たずに false
    /// (`connectedPorts`/`udids`/`engines` は Android のキーには揃わないので、
    /// この no-op が Android の呼び出しを毎回 probe しないことも兼ねて守る)
    func testPrimaryEngineDriftedIsNoOpWithoutAllThreeOfPortUDIDEngine() async {
        let server = MCPServer()
        server.connectedPorts[key] = 8123
        server.udids[key] = "SIM-1"
        // engines[key] を書かない

        let drifted = await server.primaryEngineDrifted(key)

        XCTAssertFalse(drifted, "engine を覚えていないのに判定を撃った")
    }

    // MARK: - forgetDeviceState が新しい記憶も捨てること(DeviceStateInvalidationTests の汎用走査と対)

    func testForgetDeviceStateDropsTheFallbackPort() {
        let server = MCPServer()
        server.hybridFallbackPorts[key] = 8129

        server.forgetDeviceState(key)

        XCTAssertNil(server.hybridFallbackPorts[key], "機が変わっても前の fallback ポートが残った")
    }

    // MARK: - primaryEngineOutcome(G14。純粋関数): drift していなければ現状維持、
    // drift していれば「記憶に依る呼び出しだけ拒否・依らなければ黙って作り直し」

    func testPrimaryEngineOutcomeIsUnchangedWithoutDrift() {
        let outcome = MCPServer.primaryEngineOutcome(
            drifted: false, usesRememberedDeviceState: true, port: 8123, expectedEngine: "xcuitest")
        XCTAssertEqual(outcome, .unchanged)
    }

    /// **本命**: ref を使わない呼び出し(`ft_terminate` の実測)は drift していても黙って
    /// 作り直させる —— 拒否して「撮り直せ」と言う理由が無い(その call 自身が新しいドライバで
    /// 正しく処理される)
    func testPrimaryEngineOutcomeRebuildsSilentlyWhenTheCallDoesNotUseRememberedState() {
        let outcome = MCPServer.primaryEngineOutcome(
            drifted: true, usesRememberedDeviceState: false, port: 8123, expectedEngine: "xcuitest")
        XCTAssertEqual(outcome, .rebuildSilently)
    }

    /// ref を使う呼び出しは drift していれば拒否する(ref は旧エンジンのものなので無効)
    func testPrimaryEngineOutcomeRefusesWhenTheCallUsesRememberedState() {
        let outcome = MCPServer.primaryEngineOutcome(
            drifted: true, usesRememberedDeviceState: true, port: 8123, expectedEngine: "xcuitest")
        guard case .refuse(let message) = outcome else {
            return XCTFail("記憶に依る呼び出しは拒否のはず: \(outcome)")
        }
        XCTAssertTrue(message.contains("8123"), message)
        XCTAssertTrue(message.contains("xcuitest"), message)
        XCTAssertTrue(message.contains("ft_snapshot"), message)
    }

    // MARK: - primaryEngineCheck(I/O 込みの入口): 材料が無ければ .unchanged で、
    // forgetDeviceState は呼ばない(既存の記憶を無用に捨てない)

    func testPrimaryEngineCheckIsUnchangedAndKeepsStateWithoutMaterial() async {
        let server = MCPServer()
        server.hybridFallbackPorts[key] = 8129  // primaryEngineDrifted には無関係の記憶が残っていること

        let outcome = await server.primaryEngineCheck(key, args: [:])

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(server.hybridFallbackPorts[key], 8129, "材料が無いのに forgetDeviceState を呼んだ")
    }

    // MARK: - 配線: 両方のキャッシュ命中(profile 経路・直接ポート経路)が確認を呼ぶこと
    // (DeviceStateInvalidationTests.testEveryDriverCacheHitVerifiesDeviceIdentity と対)

    func testEveryDriverCacheHitAlsoChecksThePrimaryEngineAndTheHybridFallback() throws {
        let source = try String(contentsOf: Self.driverSourceURL(), encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hits = 0
        for (index, line) in lines.enumerated() where line.contains("if let cached = drivers[key]") {
            hits += 1
            let window = lines[index..<min(index + 30, lines.count)].joined(separator: "\n")
            XCTAssertTrue(window.contains("primaryEngineCheck"),
                          "\(index + 1) 行目のキャッシュ命中がエンジンの入れ替わりを"
                          + "確かめていない —— G14 と同じ穴(udid だけ・ref を使う呼び出しだけ)が残る")
            XCTAssertTrue(window.contains("hybridFallbackDrifted"),
                          "\(index + 1) 行目のキャッシュ命中が hybrid の fallback ポートを"
                          + "確かめていない —— G6 と同じ穴(fallback だけ無検査)が残る")
        }
        XCTAssertEqual(hits, 2, "キャッシュ命中の箇所数が変わった(実測 \(hits))。増えたなら確認も入れる")
    }

    /// **両経路とも fallback ポートを記録していること**(`testBothPathsRecordWhatTheIdentityGuardNeeds`
    /// と同じ理由): 記録し忘れると `hybridFallbackDrifted` が材料無しで常に no-op になる
    func testBothPathsRecordTheHybridFallbackPort() throws {
        let source = try String(contentsOf: Self.driverSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains("hybridFallbackPorts[key] = engines[key] == \"hybrid\" ? xcuiFallbackPort : nil"),
                      "profile 経路が hybrid の fallback ポートを記録していない")
        XCTAssertTrue(source.contains("hybridFallbackPorts[key] = resolved.engine == \"hybrid\" ? resolved.xcuiPort : nil"),
                      "直接ポート経路が hybrid の fallback ポートを記録していない")
    }

    private static func driverSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Driver.swift")
    }
}
