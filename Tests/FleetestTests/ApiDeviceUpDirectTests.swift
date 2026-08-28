// device-up の --udid 直指定(マシンプロファイル未記載の実機のブリッジ起動)。
// ApiDeviceUpDirectSpec.physicalIOSSpec は I/O を持たない pure 関数なので、
// devicectl 無しで判定ロジックだけを検証する。

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

    /// **繋がっていない端末では起こさない** —— そのまま供給へ進むと xcodebuild が数分かけて
    /// 失敗する。手前で落とすのがこの関数の仕事
    func testRejectsAPairedButDisconnectedDevice() {
        XCTAssertThrowsError(try ApiDeviceUpDirectSpec.physicalIOSSpec(
            udid: "00008110-000805001188201E",
            devices: [device(udid: "00008110-000805001188201E", name: "iPhone snb", connected: false)]))
    }

    func testRejectsAnUnknownUdid() {
        XCTAssertThrowsError(try ApiDeviceUpDirectSpec.physicalIOSSpec(
            udid: "00008110-999999999999999E",
            devices: [device(udid: "00008110-000260242EEB801E", name: "iPhone SE3", connected: true)]))
    }

    /// devicectl の Identifier 列(ハードウェア UDID とは別の UUID)で指定されても引ける
    /// (IOSPhysicalDeviceCatalog.resolve と同じ許容)
    func testAcceptsTheDeviceCtlIdentifier() throws {
        let spec = try ApiDeviceUpDirectSpec.physicalIOSSpec(
            udid: "2DBFD3DF-21FE-5C6C-9F5D-1210BF80726B",
            devices: [device(udid: "00008110-000260242EEB801E", name: "iPhone SE3", connected: true,
                             identifier: "2DBFD3DF-21FE-5C6C-9F5D-1210BF80726B")])
        // spec には**ハードウェア UDID** を入れる(xcodebuild の -destination id= が受けるのはこちら)
        XCTAssertEqual(spec.udid, "00008110-000260242EEB801E")
    }
}
