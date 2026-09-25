// ポート奪取(同じポートを別の台のブリッジが答える)の検知。シナリオ実行プロセスの事前確認と
// ホスト側 bridgeUnreachable の再プローブ(BridgeProbeOutcome.hijacked)の両方が同じ判定を呼ぶ。
// BridgeIdentityCheck.verdict / expected(for:) は純粋関数なのでデバイス無しで固定できる。

import XCTest
@testable import FTCore

final class BridgeIdentityCheckTests: XCTestCase {
    private func status(device: String = "iPhone", engine: String? = "xcuitest",
                        udid: String? = nil) -> StatusResponse {
        StatusResponse(ready: true, device: device, osVersion: "-", sessionBundleID: "com.example.app",
                      engine: engine, udid: udid)
    }

    func testMatchingUDIDIsOK() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: "SIM-1", physical: false, engine: "xcuitest")
        XCTAssertEqual(BridgeIdentityCheck.verdict(expected: expected, status: status(udid: "SIM-1"), remedy: "REMEDY"), .ok)
    }

    func testDifferingUDIDIsMismatch() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: "SIM-1", physical: false, engine: "xcuitest")
        guard case .mismatch = BridgeIdentityCheck.verdict(expected: expected, status: status(udid: "SIM-2"), remedy: "REMEDY") else {
            return XCTFail("別 UDID は mismatch のはず")
        }
    }

    /// 実測の F8b: 実機(udid は物理識別子。status には出ない)の期待に対し、
    /// ポートを奪った相手がシミュレータの in-app ブリッジで応答した
    func testNoStatusUDIDPhysicalExpectedButEngineInappIsMismatch() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: "PHYSICAL-SE3", physical: true, engine: nil)
        guard case .mismatch = BridgeIdentityCheck.verdict(
            expected: expected, status: status(engine: "inapp", udid: nil), remedy: "REMEDY") else {
            return XCTFail("実機期待で engine=inapp は mismatch のはず(実機に in-app は無い)")
        }
    }

    func testNoStatusUDIDExpectedXcuitestButEngineInappIsMismatch() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: nil, physical: false, engine: "xcuitest")
        guard case .mismatch = BridgeIdentityCheck.verdict(
            expected: expected, status: status(engine: "inapp", udid: nil), remedy: "REMEDY") else {
            return XCTFail("xcuitest 期待で engine=inapp は mismatch のはず")
        }
    }

    /// 逆向き(期待が inapp、相手が xcuitest)も同じ規則で mismatch にする
    func testNoStatusUDIDExpectedInappButEngineXcuitestIsMismatch() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: nil, physical: false, engine: "inapp")
        guard case .mismatch = BridgeIdentityCheck.verdict(
            expected: expected, status: status(engine: "xcuitest", udid: nil), remedy: "REMEDY") else {
            return XCTFail("inapp 期待で engine=xcuitest は mismatch のはず")
        }
    }

    /// 判断材料が無ければ通す(fail-closed で健全な run を落とさない)
    func testNoMaterialIsOK() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: nil, physical: true, engine: nil)
        XCTAssertEqual(
            BridgeIdentityCheck.verdict(expected: expected, status: status(engine: nil, udid: nil), remedy: "REMEDY"), .ok)
    }

    /// status に udid が無く、engine も同じ分類(どちらも非 inapp)なら ok
    func testNoStatusUDIDMatchingEngineClassIsOK() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: nil, physical: true, engine: nil)
        XCTAssertEqual(
            BridgeIdentityCheck.verdict(expected: expected, status: status(engine: "xcuitest", udid: nil), remedy: "REMEDY"), .ok)
    }

    /// status に udid はあるが expected 側が udid を持たない(--udid 未指定)ときは判断できないので通す
    func testStatusUDIDWithoutExpectedUDIDIsOK() {
        let expected = BridgeIdentityCheck.Expected(port: 8138, udid: nil, physical: false, engine: "xcuitest")
        XCTAssertEqual(BridgeIdentityCheck.verdict(expected: expected, status: status(udid: "SIM-9"), remedy: "REMEDY"), .ok)
    }

    // MARK: - DriverError への写像(壊れたら落ちることの確認: bridgeIdentityMismatch を
    // .driverError 等へ誤って倒すと、この等号が落ちる)

    func testBridgeIdentityMismatchMapsToDriverUnreachable() {
        let error = DriverError.bridgeIdentityMismatch("the bridge on port 8138 now belongs to another device")
        XCTAssertEqual(error.stepFailureKind, .driverUnreachable)
    }

    // ホスト側プローブの期待値: xcuiPort を叩くときだけ期待エンジンが xcuitest に固定される
    // (hybrid の in-app 側を期待にすると、xcuitest ランナーの正しい応答を mismatch と誤検知する)
    func testExpectedForHybridConnectionProbedAtXCUIPortExpectsXcuitest() {
        let connection = DriverConnection(platform: "ios", port: 8138, engine: "hybrid", udid: "SIM-1",
                                          xcuiPort: 8124, deviceName: "iPhone 17 Pro-01")
        let expected = BridgeIdentityCheck.expected(for: connection, probedPort: 8124)
        XCTAssertEqual(expected.engine, "xcuitest")
        XCTAssertEqual(expected.udid, "SIM-1")
        XCTAssertEqual(expected.port, 8124)
        XCTAssertFalse(expected.physical)
        XCTAssertEqual(BridgeIdentityCheck.verdict(expected: expected, status: status(engine: "xcuitest"), remedy: "REMEDY"), .ok)
    }

    func testExpectedForConnectionProbedAtItsOwnPortKeepsTheConnectionEngine() {
        let connection = DriverConnection(platform: "ios", port: 8138, engine: "inapp", udid: "SIM-1")
        let expected = BridgeIdentityCheck.expected(for: connection, probedPort: 8138)
        XCTAssertEqual(expected.engine, "inapp")
        XCTAssertEqual(BridgeIdentityCheck.verdict(expected: expected, status: status(engine: "inapp"), remedy: "REMEDY"), .ok)
        guard case .mismatch = BridgeIdentityCheck.verdict(expected: expected, status: status(engine: "xcuitest"), remedy: "REMEDY") else {
            return XCTFail("in-app 期待のポートに xcuitest ランナーが答えたら mismatch のはず")
        }
    }

    // 実測の形(2026-09-15): 実機 SE3(xcuitest)のポートを sim -01 の in-app ブリッジが奪った
    func testPhysicalConnectionAnsweredByAnInAppBridgeIsMismatch() {
        let connection = DriverConnection(platform: "ios", port: 8138, engine: "xcuitest",
                                          udid: "00008110-000260242EEB801E", physical: true, host: "127.0.0.1")
        let expected = BridgeIdentityCheck.expected(for: connection, probedPort: 8138)
        guard case .mismatch = BridgeIdentityCheck.verdict(
            expected: expected, status: status(device: "iPhone 17 Pro(iOS 27.0)-01", engine: "inapp"), remedy: "REMEDY") else {
            return XCTFail("実機期待のポートに in-app ブリッジが答えたら mismatch のはず")
        }
    }

    // MARK: - hybridFallbackDrift(maintainer-notes §51.2。hybrid が主とは別に握るポートの本人確認。
    // 呼び手は MCP とライブ操作(api live serve)の2つ、どちらも FTBridgeClient.HybridFallbackIdentity 経由)

    /// **本命**: fallback ポートが今は別デバイスの XCUITest ブリッジ。以前は無検査で
    /// キャッシュ/使い回されたドライバがそのまま撃たれていた。**udid が違う形は differentDevice**
    /// (エンジンも違えば同時に食い違っていても、機が違う事実のほうを優先する)
    func testHybridFallbackDriftDetectsADifferentUDID() {
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8129, expectedUDID: "SIM-1", status: status(engine: "xcuitest", udid: "SIM-2")),
            .differentDevice, "fallback ポートが別デバイスの udid を名乗っているのに一致と判定した")
    }

    /// **maintainer-notes §51.2 の実測**: 建て直しで fallback ポートが in-app ブリッジに化けた(XCUITest ではない)。
    /// in-app には `/gesture` が無いので 404 になるが、相手が同じデバイスの別ポートとは限らない。
    /// udid が申告されない(実機の xcuitest しか取り得ない形)ので、エンジンの食い違いは
    /// differentDevice に分類する(実機 ⇄ シミュレータの入れ替わりでしか起こらない)
    func testHybridFallbackDriftDetectsTheFallbackPortNowAnsweringAsInApp() {
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8129, expectedUDID: "SIM-1", status: status(engine: "inapp", udid: nil)),
            .differentDevice, "fallback ポートが in-app を名乗っているのに一致と判定した")
    }

    /// 同じ台(udid 一致)の in-app ブリッジが予備ポートに居る形は **sameDeviceEngineChanged**
    /// (別デバイスではない —— MCP はこれを ref 依存呼び出しだけ拒否・非依存は黙って作り直す)
    func testHybridFallbackDriftDetectsSameDeviceInAppOnTheFallbackPortAsEngineChanged() {
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8129, expectedUDID: "SIM-1", status: status(engine: "inapp", udid: "SIM-1")),
            .sameDeviceEngineChanged, "同じ udid の in-app を XCUITest の予備と取り違えた")
    }

    func testHybridFallbackDriftIsNoneWhenTheUDIDStillMatches() {
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8129, expectedUDID: "SIM-1", status: status(engine: "xcuitest", udid: "SIM-1")), .none)
    }

    /// `expectedEngine` はライブ操作が in-app 側(主)を確かめるのに使う(同じ判定を2つ持たない)
    func testHybridFallbackDriftCanExpectInAppForThePrimarySide() {
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8123, expectedUDID: "SIM-1", expectedEngine: "inapp",
            status: status(engine: "inapp", udid: "SIM-1")), .none)
        XCTAssertEqual(BridgeIdentityCheck.hybridFallbackDrift(
            port: 8123, expectedUDID: "SIM-1", expectedEngine: "inapp",
            status: status(engine: "xcuitest", udid: "SIM-1")),
            .sameDeviceEngineChanged, "in-app を期待しているのに xcuitest が答えたら engine 違いのはず")
    }
}
