// device-up の --udid 直指定(マシンプロファイル未記載の実機のブリッジ起動)。
// ApiDeviceUpDirectSpec.physicalIOSSpec の I/O は到達性の probe だけなので、
// **必ず probe を注入して**devicectl 無しで判定ロジックだけを検証する
// (注入を省くと本物の devicectl を撃つ = 単体テストがホストの実機構成に依存する)。

import FTBridgeClient
import FTCore
import XCTest

@testable import fleetest

final class ApiDeviceUpDirectTests: XCTestCase {

    private func device(udid: String, name: String, connected: Bool,
                        identifier: String? = nil) -> IOSPhysicalDeviceInfo {
        IOSPhysicalDeviceInfo(udid: udid, name: name, os: "iOS 26.6", connected: connected,
                              transport: "wired", deviceCtlIdentifier: identifier)
    }

    func testBuildsAPhysicalSpecForAConnectedDevice() throws {
        let spec = try ApiDeviceUpDirectSpec.physicalIOSSpec(
            udid: "00008110-000260242EEB801E",
            devices: [device(udid: "00008110-000260242EEB801E", name: "iPhone SE3", connected: true)])
        XCTAssertEqual(spec.name, "iPhone SE3")
        XCTAssertEqual(spec.udid, "00008110-000260242EEB801E")
        XCTAssertTrue(spec.isPhysical)
        // 実機に in-app 注入は無い(`fleetest bridge up --physical` と同じ engine)
        XCTAssertEqual(spec.engine, "xcuitest")
    }

    /// **本当に届かない端末では起こさない** —— そのまま供給へ進むと xcodebuild が数分かけて
    /// 失敗する。手前で落とすのがこの関数の仕事
    func testRejectsADeviceThatNeitherTheListNorTheProbeCanReach() {
        XCTAssertThrowsError(try ApiDeviceUpDirectSpec.physicalIOSSpec(
            udid: "00008110-000805001188201E",
            devices: [device(udid: "00008110-000805001188201E", name: "iPhone snb", connected: false)],
            probe: { _ in false }))
    }

    /// **一覧の「未接続」だけで拒否しない**: 有線で待機中の端末は CoreDevice がトンネルを畳むので
    /// `list devices` は disconnected と言うが、名指しで問い合わせれば繋がる(2026-09-04 実測:
    /// USB の iPhone SE3)。そこに無い端末と同じ値なので、訊く前に断ると使える端末を拒否する
    func testAcceptsAWiredDeviceTheListCallsDisconnectedWhenTheProbeReachesIt() throws {
        let spec = try ApiDeviceUpDirectSpec.physicalIOSSpec(
            udid: "00008110-000260242EEB801E",
            devices: [device(udid: "00008110-000260242EEB801E", name: "iPhone SE3", connected: false)],
            probe: { _ in true })
        XCTAssertEqual(spec.name, "iPhone SE3")
        XCTAssertTrue(spec.isPhysical)
    }

    /// 一覧が接続中と言っているなら訊かない(devicectl の往復を毎回払わない)
    func testDoesNotProbeWhenTheListAlreadySaysConnected() throws {
        var probed: [String] = []
        _ = try ApiDeviceUpDirectSpec.physicalIOSSpec(
            udid: "00008110-000260242EEB801E",
            devices: [device(udid: "00008110-000260242EEB801E", name: "iPhone SE3", connected: true)],
            probe: { probed.append($0); return true })
        XCTAssertEqual(probed, [])
    }

    func testRejectsAnUnknownUdid() {
        XCTAssertThrowsError(try ApiDeviceUpDirectSpec.physicalIOSSpec(
            udid: "00008110-999999999999999E",
            devices: [device(udid: "00008110-000260242EEB801E", name: "iPhone SE3", connected: true)],
            probe: { _ in true }))
    }

    /// devicectl の Identifier 列(ハードウェア UDID とは別の UUID)で指定されても引ける
    /// (IOSPhysicalDeviceCatalog.resolve と同じ許容)
    func testAcceptsTheDeviceCtlIdentifier() throws {
        let spec = try ApiDeviceUpDirectSpec.physicalIOSSpec(
            udid: "2DBFD3DF-21FE-5C6C-9F5D-1210BF80726B",
            devices: [device(udid: "00008110-000260242EEB801E", name: "iPhone SE3", connected: true,
                             identifier: "2DBFD3DF-21FE-5C6C-9F5D-1210BF80726B")],
            probe: { _ in true })
        // spec には**ハードウェア UDID** を入れる(xcodebuild の -destination id= が受けるのはこちら)
        XCTAssertEqual(spec.udid, "00008110-000260242EEB801E")
    }
}
