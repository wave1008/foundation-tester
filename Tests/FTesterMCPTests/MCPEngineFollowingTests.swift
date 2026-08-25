// **MCP の iOS ドライバが実行プロファイルのエンジンに追従する**ことを固定する。
//
// ここが静かに XCUITest 固定へ戻ると、探索(ft_*)と実行(ft_run_scenario)で
// **snapshot の中身もジェスチャの成否も変わる** —— 探索で採ったセレクタが実行時に無い、
// MCP では無反応なのにシナリオでは通る、といった食い違いが起きる(2026-08-04 まで実際にそうだった)。
//
// **xcuitest 経路は対象外**: XCUIBridgeResolver がブリッジを探索する(ネットワーク)ため、
// デバイス無しでは呼べない。ここで守るのは「inapp/hybrid のとき in-app 側を主にする」こと。

import XCTest
import FTCore
import FTBridgeClient
@testable import ftester_mcp

final class MCPEngineFollowingTests: XCTestCase {

    private func provisioned(engine: String, xcuiPort: UInt16?,
                             physical: Bool = false) -> ProvisionedIOSDevice {
        ProvisionedIOSDevice(name: "sim1", udid: "UDID-1", simulatorName: "iPhone 17 Pro",
                            port: 8123, engine: engine, xcuiPort: xcuiPort, physical: physical)
    }

    /// hybrid = in-app を主に、XCUITest をフォールバックに持つ合成(実行側と同じ形)
    func testHybridComposesInAppWithXCUITestFallback() async throws {
        let (driver, _) = try await MCPServer.iosDriver(
            provisioned: provisioned(engine: "hybrid", xcuiPort: 8124),
            bundleID: "com.example.app")
        XCTAssertTrue(driver is HybridFallbackDriver,
                      "hybrid は「不可な操作だけ XCUITest へ回す」合成にすること: \(type(of: driver))")
    }

    /// inapp 単独はフォールバック先が無いので素の in-app
    func testInAppEngineUsesTheInAppDriverDirectly() async throws {
        let (driver, _) = try await MCPServer.iosDriver(
            provisioned: provisioned(engine: "inapp", xcuiPort: nil),
            bundleID: "com.example.app")
        XCTAssertTrue(driver is InAppDriver, "\(type(of: driver))")
    }

    /// hybrid でも**対象アプリが分からなければ** attach できないので素の in-app へ落とす
    /// (AppAttachDriver は bundleID が必須)
    func testHybridWithoutBundleIDFallsBackToInAppOnly() async throws {
        let (driver, _) = try await MCPServer.iosDriver(
            provisioned: provisioned(engine: "hybrid", xcuiPort: 8124), bundleID: nil)
        XCTAssertTrue(driver is InAppDriver, "\(type(of: driver))")
    }

    /// **実機は注入できない**ので、engine の申告に関わらず in-app 側を作らない
    /// (作ると dylib 注入を試みて必ず失敗する)
    func testPhysicalDeviceNeverUsesTheInAppEngine() async throws {
        let (driver, _) = try await MCPServer.iosDriver(
            provisioned: provisioned(engine: "hybrid", xcuiPort: 8124, physical: true),
            bundleID: "com.example.app")
        XCTAssertFalse(driver is HybridFallbackDriver, "実機で in-app 合成を作ってはいけない")
        XCTAssertFalse(driver is InAppDriver, "実機で in-app 合成を作ってはいけない")
    }

    // MARK: - probePort(同一性を確かめに行ってよい loopback のポート。2026-08-13)

    /// **実機には probePort を出さない**。実機のブリッジは loopback ではないので、
    /// ポート番号だけで 127.0.0.1 を叩くと**無関係なシミュレータのブリッジを読む** ——
    /// `deviceIdentityChanged` が別の機の udid を見て、正しい呼び出しを拒否し記憶まで捨てる
    func testPhysicalDeviceHasNoLoopbackProbePort() async throws {
        let (_, probePort) = try await MCPServer.iosDriver(
            provisioned: provisioned(engine: "hybrid", xcuiPort: 8124, physical: true),
            bundleID: "com.example.app")
        XCTAssertNil(probePort, "実機に loopback の probe ポートを出した")
    }

    /// in-app / hybrid は主(in-app)のポートを probe に使う
    func testInAppEngineProbesItsOwnPort() async throws {
        let (_, probePort) = try await MCPServer.iosDriver(
            provisioned: provisioned(engine: "inapp", xcuiPort: nil), bundleID: "com.example.app")
        XCTAssertEqual(probePort, 8123)
    }
}
