// CLI(手動駆動サブコマンド)と MCP(ft_*)が共有する宛先解決の構造化エラー
// (`FTBridgeClient.BridgeTargetError` / `FTAndroid.AndroidTargetError`)と、
// ブリッジ版ズレの判定(`FTBridgeClient.BridgeVersionSkew`)を固定する。
//
// **新しい判定ロジックはここに増やさない**: 「1本だけなら自動採用・複数なら拒否」の実体は
// 純粋関数 `BridgeDiscovery.decide` / `AndroidSerialResolver.decide`(既存の
// BridgeDiscoveryTests / AndroidSerialResolverTests が固定済み)。ここで確かめるのは
// **構造化エラーの `message(_:)` が、その判定に対応する文言関数とバイト一致すること**だけ
// (MCP と CLI が同じ文言を包んで返せることの保証)。

import XCTest
import FTBridgeClient
import FTCore
import FTAndroid

final class BridgeTargetErrorTests: XCTestCase {

    func testBusyMatchesBridgeDiscoveryMessage() {
        let error = BridgeTargetError.busy(preferred: 8123)
        XCTAssertEqual(error.message(.mcp), BridgeDiscovery.busyMessage(preferred: 8123, names: .mcp))
    }

    func testNoBridgeMatchesBridgeDiscoveryMessage() {
        let error = BridgeTargetError.noBridge(preferred: 8123)
        XCTAssertEqual(error.message(.mcp), BridgeDiscovery.noBridgeMessage(preferred: 8123, names: .mcp))
    }

    func testUnansweredMatchesBridgeDiscoveryMessage() {
        let found = [BridgeDiscovery.Found(port: 8124, device: "iPhone 17", engine: "xcuitest")]
        let silent = [BridgeDiscovery.Silent(port: 8128)]
        let error = BridgeTargetError.unanswered(preferred: 8123, found: found, silent: silent)
        XCTAssertEqual(error.message(.mcp),
                       BridgeDiscovery.unansweredMessage(preferred: 8123, found: found, silent: silent, names: .mcp))
    }

    func testAmbiguousMatchesBridgeDiscoveryMessage() {
        let found = [
            BridgeDiscovery.Found(port: 8124, device: "iPhone 17", engine: "xcuitest"),
            BridgeDiscovery.Found(port: 8130, device: "iPad Pro", engine: "inapp"),
        ]
        let error = BridgeTargetError.ambiguous(preferred: 8123, found: found)
        XCTAssertEqual(error.message(.cliRun),
                       BridgeDiscovery.ambiguousMessage(preferred: 8123, found: found, names: .cliRun))
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
        XCTAssertEqual(AndroidTargetError.noDevice.message(.mcp),
                       AndroidSerialResolver.noDeviceMessage)
    }

    func testAmbiguousMatchesAndroidSerialResolverMessage() {
        let devices = [
            AndroidSerialResolver.Device(serial: "emulator-5554", avd: "Pixel_7_API_34"),
            AndroidSerialResolver.Device(serial: "R3CN123", avd: nil),
        ]
        let error = AndroidTargetError.ambiguous(devices: devices)
        XCTAssertEqual(error.message(.cliManual),
                       AndroidSerialResolver.ambiguousMessage(devices, names: .cliManual))
    }
}

/// 引数名は呼び手のもの: CLI の手動駆動に MCP の `port:` / `profile:` を案内しない
final class TargetArgumentNamesMessageTests: XCTestCase {

    private let found = [
        BridgeDiscovery.Found(port: 8124, device: "iPhone 17", engine: "xcuitest"),
        BridgeDiscovery.Found(port: 8130, device: "iPad Pro", engine: "inapp"),
    ]
    private let devices = [
        AndroidSerialResolver.Device(serial: "emulator-5554", avd: nil),
        AndroidSerialResolver.Device(serial: "R3CN123", avd: nil),
    ]

    func testCliManualNamesFlagsAndOffersNoProfile() {
        let ios = BridgeTargetError.ambiguous(preferred: 8123, found: found).message(.cliManual)
        let android = AndroidTargetError.ambiguous(devices: devices).message(.cliManual)
        XCTAssertTrue(ios.contains("--port"), ios)
        XCTAssertTrue(android.contains("--serial"), android)
        for text in [ios, android] {
            XCTAssertFalse(text.contains("port:"), text)
            XCTAssertFalse(text.contains("serial:"), text)
            XCTAssertFalse(text.contains("profile"), text)
        }
    }

    func testCliRunOffersDashDashProfile() {
        let ios = BridgeTargetError.ambiguous(preferred: 8123, found: found).message(.cliRun)
        let android = AndroidTargetError.ambiguous(devices: devices).message(.cliRun)
        XCTAssertTrue(ios.contains("--profile"), ios)
        XCTAssertTrue(android.contains("--profile"), android)
    }

    func testMcpKeepsColonStyleArguments() {
        let ios = BridgeTargetError.ambiguous(preferred: 8123, found: found).message(.mcp)
        let android = AndroidTargetError.ambiguous(devices: devices).message(.mcp)
        XCTAssertTrue(ios.contains("port:") && ios.contains("profile:"), ios)
        XCTAssertTrue(android.contains("serial:") && android.contains("profile:"), android)
    }
}
