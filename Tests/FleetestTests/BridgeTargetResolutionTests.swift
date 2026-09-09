// CLI(手動駆動サブコマンド)と MCP(ft_*)が共有する宛先解決の構造化エラー
// (`FTBridgeClient.BridgeTargetError` / `FTAndroid.AndroidTargetError`)と、
// ブリッジ版ズレの判定(`FTBridgeClient.BridgeVersionSkew`)を固定する。
//
// **新しい判定ロジックはここに増やさない**: 「1本だけなら自動採用・複数なら拒否」の実体は
// 純粋関数 `BridgeDiscovery.decide` / `AndroidSerialResolver.decide`(既存の
// BridgeDiscoveryTests / AndroidSerialResolverTests が固定済み)。ここで確かめるのは
// **構造化エラーの `errorDescription` が、その判定に対応する文言関数とバイト一致すること**だけ
// (MCP と CLI が同じ文言を包んで返せることの保証)。

import XCTest
import FTBridgeClient
import FTAndroid

final class BridgeTargetErrorTests: XCTestCase {

    func testBusyMatchesBridgeDiscoveryMessage() {
        let error = BridgeTargetError.busy(preferred: 8123)
        XCTAssertEqual(error.errorDescription, BridgeDiscovery.busyMessage(preferred: 8123))
    }

    func testNoBridgeMatchesBridgeDiscoveryMessage() {
        let error = BridgeTargetError.noBridge(preferred: 8123)
        XCTAssertEqual(error.errorDescription, BridgeDiscovery.noBridgeMessage(preferred: 8123))
    }

    func testAmbiguousMatchesBridgeDiscoveryMessage() {
        let found = [
            BridgeDiscovery.Found(port: 8124, device: "iPhone 17", engine: "xcuitest"),
            BridgeDiscovery.Found(port: 8130, device: "iPad Pro", engine: "inapp"),
        ]
        let error = BridgeTargetError.ambiguous(preferred: 8123, found: found)
        XCTAssertEqual(error.errorDescription,
                       BridgeDiscovery.ambiguousMessage(preferred: 8123, found: found))
    }
}

final class BridgeVersionSkewTests: XCTestCase {

    func testBridgeNewerThanBuild() {
        let skew = BridgeVersionSkew(running: 92, expected: 91)
        XCTAssertTrue(skew.bridgeIsNewer)
    }

    func testBridgeOlderThanBuild() {
        let skew = BridgeVersionSkew(running: 90, expected: 91)
        XCTAssertFalse(skew.bridgeIsNewer)
    }
}

final class AndroidTargetErrorTests: XCTestCase {

    func testNoDeviceMatchesAndroidSerialResolverMessage() {
        XCTAssertEqual(AndroidTargetError.noDevice.errorDescription,
                       AndroidSerialResolver.noDeviceMessage)
    }

    func testAmbiguousMatchesAndroidSerialResolverMessage() {
        let devices = [
            AndroidSerialResolver.Device(serial: "emulator-5554", avd: "Pixel_7_API_34"),
            AndroidSerialResolver.Device(serial: "R3CN123", avd: nil),
        ]
        let error = AndroidTargetError.ambiguous(devices: devices)
        XCTAssertEqual(error.errorDescription, AndroidSerialResolver.ambiguousMessage(devices))
    }
}
