// ポート奪取(同じポートを別のデバイスのブリッジが答える)の検知。シナリオ実行プロセスの事前確認と
// ホスト側 bridgeUnreachable の再プローブ(BridgeProbeOutcome.hijacked)の両方が同じ判定を呼ぶ。
// BridgeIdentityCheck.verdict / expected(for:) は純粋関数なのでデバイス無しで固定できる。

import XCTest
@testable import FTCore

final class BridgeIdentityCheckTests: XCTestCase {
    private func status(device: String = "iPhone", bridge: String? = "xcuitest",
                        udid: String? = nil) -> StatusResponse {
        StatusResponse(ready: true, device: device, osVersion: "-", sessionBundleID: "com.example.app",
                      bridge: bridge, udid: udid)
    }

    func testMatchingUDIDIsOK() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: "SIM-1", physical: false, bridge: "xcuitest")
        XCTAssertEqual(BridgeIdentityCheck.verdict(expected: expected, status: status(udid: "SIM-1"), remedy: "REMEDY"), .ok)
    }

    func testDifferingUDIDIsMismatch() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: "SIM-1", physical: false, bridge: "xcuitest")
        guard case .mismatch = BridgeIdentityCheck.verdict(expected: expected, status: status(udid: "SIM-2"), remedy: "REMEDY") else {
            return XCTFail("別 UDID は mismatch のはず")
        }
    }

    /// 実測の F8b: 実機(udid は物理識別子。status には出ない)の期待に対し、
    /// ポートを奪った相手がシミュレータの in-app ブリッジで応答した
    func testNoStatusUDIDPhysicalExpectedButBridgeInappIsMismatch() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: "PHYSICAL-SE3", physical: true, bridge: nil)
        guard case .mismatch = BridgeIdentityCheck.verdict(
            expected: expected, status: status(bridge: "inapp", udid: nil), remedy: "REMEDY") else {
            return XCTFail("実機期待で bridge=inapp は mismatch のはず(実機に in-app は無い)")
        }
    }

    func testNoStatusUDIDExpectedXcuitestButBridgeInappIsMismatch() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: nil, physical: false, bridge: "xcuitest")
        guard case .mismatch = BridgeIdentityCheck.verdict(
            expected: expected, status: status(bridge: "inapp", udid: nil), remedy: "REMEDY") else {
            return XCTFail("xcuitest 期待で bridge=inapp は mismatch のはず")
        }
    }

    /// 実機の in-app 対応: 実機のレーンが in-app を期待し、相手も in-app(udid は両側 nil)なら ok。
    /// ポートはデバイスを跨いで一意なので、実機の in-app が udid を申告できなくてもブリッジ種別の一致で通す
    func testNoStatusUDIDPhysicalExpectedInappAndBridgeInappIsOK() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: "PHYSICAL-SE3", physical: true, bridge: "inapp")
        XCTAssertEqual(
            BridgeIdentityCheck.verdict(expected: expected, status: status(bridge: "inapp", udid: nil), remedy: "REMEDY"),
            .ok, "実機 + in-app はもう乗っ取りではない")
    }

    /// 逆向き(期待が inapp、相手が xcuitest)も同じ規則で mismatch にする
    func testNoStatusUDIDExpectedInappButBridgeXcuitestIsMismatch() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: nil, physical: false, bridge: "inapp")
        guard case .mismatch = BridgeIdentityCheck.verdict(
            expected: expected, status: status(bridge: "xcuitest", udid: nil), remedy: "REMEDY") else {
            return XCTFail("inapp 期待で bridge=xcuitest は mismatch のはず")
        }
    }

    /// 判断材料が無ければ通す(fail-closed で健全な run を落とさない)
    func testNoMaterialIsOK() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: nil, physical: true, bridge: nil)
        XCTAssertEqual(
            BridgeIdentityCheck.verdict(expected: expected, status: status(bridge: nil, udid: nil), remedy: "REMEDY"), .ok)
    }

    /// status に udid が無く、bridge も同じ分類(どちらも非 inapp)なら ok
    func testNoStatusUDIDMatchingBridgeClassIsOK() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: nil, physical: true, bridge: nil)
        XCTAssertEqual(
            BridgeIdentityCheck.verdict(expected: expected, status: status(bridge: "xcuitest", udid: nil), remedy: "REMEDY"), .ok)
    }

    /// status に udid はあるが expected 側が udid を持たない(--udid 未指定)ときは判断できないので通す
    func testStatusUDIDWithoutExpectedUDIDIsOK() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: nil, physical: false, bridge: "xcuitest")
        XCTAssertEqual(BridgeIdentityCheck.verdict(expected: expected, status: status(udid: "SIM-9"), remedy: "REMEDY"), .ok)
    }

    // MARK: - DriverError への写像(壊れたら落ちることの確認: bridgeIdentityMismatch を
    // .driverError 等へ誤って倒すと、この等号が落ちる)

    func testBridgeIdentityMismatchMapsToDriverUnreachable() {
        let error = DriverError.bridgeIdentityMismatch("the bridge on port 8138 now belongs to another device")
        XCTAssertEqual(error.stepFailureKind, .driverUnreachable)
    }

    // ホスト側プローブの期待値: xcuiPort を叩くときだけ期待ブリッジが xcuitest に固定される
    // (inapp モードの in-app 側を期待にすると、xcuitest ランナーの正しい応答を mismatch と誤検知する)
    func testExpectedForInappModeConnectionProbedAtXCUIPortExpectsXcuitest() {
        let connection = DriverConnection(platform: "ios", port: 8138, mode: "inapp", udid: "SIM-1",
                                          xcuiPort: 8124, deviceName: "iPhone 17 Pro-01")
        let expected = BridgeIdentityCheck.expected(for: connection, probedPort: 8124)
        XCTAssertEqual(expected.bridge, "xcuitest")
        XCTAssertEqual(expected.udid, "SIM-1")
        XCTAssertEqual(expected.port, 8124)
        XCTAssertFalse(expected.physical)
        XCTAssertEqual(BridgeIdentityCheck.verdict(expected: expected, status: status(bridge: "xcuitest"), remedy: "REMEDY"), .ok)
    }

    func testExpectedForConnectionProbedAtItsOwnPortKeepsTheConnectionBridge() {
        let connection = DriverConnection(platform: "ios", port: 8138, mode: "inapp", udid: "SIM-1")
        let expected = BridgeIdentityCheck.expected(for: connection, probedPort: 8138)
        XCTAssertEqual(expected.bridge, "inapp")
        XCTAssertEqual(BridgeIdentityCheck.verdict(expected: expected, status: status(bridge: "inapp"), remedy: "REMEDY"), .ok)
        guard case .mismatch = BridgeIdentityCheck.verdict(expected: expected, status: status(bridge: "xcuitest"), remedy: "REMEDY") else {
            return XCTFail("in-app 期待のポートに xcuitest ランナーが答えたら mismatch のはず")
        }
    }

    // 実測の形(2026-09-15): 実機 SE3(xcuitest)のポートを sim -01 の in-app ブリッジが奪った
    func testPhysicalConnectionAnsweredByAnInAppBridgeIsMismatch() {
        let connection = DriverConnection(platform: "ios", port: 8138, mode: "xcuitest",
                                          udid: "00008110-000260242EEB801E", physical: true, host: "127.0.0.1")
        let expected = BridgeIdentityCheck.expected(for: connection, probedPort: 8138)
        guard case .mismatch = BridgeIdentityCheck.verdict(
            expected: expected, status: status(device: "iPhone 17 Pro(iOS 27.0)-01", bridge: "inapp"), remedy: "REMEDY") else {
            return XCTFail("実機期待のポートに in-app ブリッジが答えたら mismatch のはず")
        }
    }

    // MARK: - hybridFallbackDrift(maintainer-notes §51.2。inapp モードが主とは別に握るポートの本人確認。
    // 呼び手は MCP とライブ操作(api live serve)の2つ、どちらも FTBridgeClient.HybridFallbackIdentity 経由)

    /// **本命**: fallback ポートが今は別デバイスの XCUITest ブリッジ。以前は無検査で
    /// キャッシュ/使い回されたドライバがそのまま撃たれていた。**udid が違う形は differentDevice**
    /// (ブリッジも違えば同時に食い違っていても、機が違う事実のほうを優先する)
    func testHybridFallbackDriftDetectsADifferentUDID() {
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8129, expectedUDID: "SIM-1", status: status(bridge: "xcuitest", udid: "SIM-2")),
            .differentDevice, "fallback ポートが別デバイスの udid を名乗っているのに一致と判定した")
    }

    /// **maintainer-notes §51.2 の実測**: 起動し直しで fallback ポートが in-app ブリッジに化けた(XCUITest ではない)。
    /// in-app には `/gesture` が無いので 404 になるが、相手が同じデバイスの別ポートとは限らない。
    /// udid が申告されない(実機の xcuitest しか取り得ない形)ので、ブリッジの食い違いは
    /// differentDevice に分類する(実機 ⇄ シミュレータの入れ替わりでしか起こらない)
    func testHybridFallbackDriftDetectsTheFallbackPortNowAnsweringAsInApp() {
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8129, expectedUDID: "SIM-1", status: status(bridge: "inapp", udid: nil)),
            .differentDevice, "fallback ポートが in-app を名乗っているのに一致と判定した")
    }

    /// 同じデバイス(udid 一致)の in-app ブリッジが予備ポートに居る形は **sameDeviceBridgeChanged**
    /// (別デバイスではない —— MCP はこれを ref 依存呼び出しだけ拒否・非依存は黙って作り直す)
    func testHybridFallbackDriftDetectsSameDeviceInAppOnTheFallbackPortAsBridgeChanged() {
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8129, expectedUDID: "SIM-1", status: status(bridge: "inapp", udid: "SIM-1")),
            .sameDeviceBridgeChanged, "同じ udid の in-app を XCUITest の予備と取り違えた")
    }

    func testHybridFallbackDriftIsNoneWhenTheUDIDStillMatches() {
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8129, expectedUDID: "SIM-1", status: status(bridge: "xcuitest", udid: "SIM-1")), .none)
    }

    /// `expectedBridge` はライブ操作が in-app 側(主)を確かめるのに使う(同じ判定を2つ持たない)
    func testHybridFallbackDriftCanExpectInAppForThePrimarySide() {
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8123, expectedUDID: "SIM-1", expectedBridge: "inapp",
            status: status(bridge: "inapp", udid: "SIM-1")), .none)
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8123, expectedUDID: "SIM-1", expectedBridge: "inapp",
            status: status(bridge: "xcuitest", udid: "SIM-1")),
            .sameDeviceBridgeChanged, "in-app を期待しているのに xcuitest が答えたら bridge 違いのはず")
    }

    /// シナリオ実行バイナリの事前確認が駆るのは XCUITest ブリッジだけ。モードを期待に渡すと、inapp モードで
    /// 別アプリを XCUITest ブリッジへ回したとき、udid を名乗らない実機のランナーが「別のブリッジ」と誤判定される
    func testScenarioRunnerPreflightExpectsTheXCUITestBridge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/FTScenarioRunner/ScenarioRunnerMain.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("port: preflightPort, udid: udid, physical: physical, bridge: IOSMode.xcuitest,"))
        XCTAssertTrue(source.contains("preflightPort = xcuiPort"), "別アプリの分岐で突き合わせるポートを XCUITest 側へ向けていない")
        // 判定そのもの: 実機(udid なし)の XCUITest ランナーに in-app を期待すると誤って食い違う
        let wrong = BridgeIdentityCheck.Expected(port: 8124, udid: "PHYS", physical: true, bridge: "inapp")
        guard case .mismatch = BridgeIdentityCheck.verdict(
            expected: wrong, status: status(bridge: "xcuitest", udid: nil), remedy: "R") else {
            return XCTFail("前提: in-app を期待すると xcuitest の実機ランナーは mismatch になる")
        }
    }
}
