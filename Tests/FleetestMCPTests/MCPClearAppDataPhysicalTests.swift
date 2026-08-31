// ft_clear_app_data on a physical device.
//
// BridgeClient.clearAppData throws 501 ("clearAppData is simulator-only on iOS — devicectl has
// no equivalent; reinstall the app instead") on a physical device, and MCP used to let that 501
// surface as-is. Since a reinstall needs a package path, and MCP already remembers the last
// ft_install packagePath per engineKey (installedPackagePaths), it can do the reinstall itself
// instead of handing the caller a dead end.

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPClearAppDataPhysicalTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!
    private let key = MCPServer.engineKey([:])

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private static let physicalOnly501 = DriverError.badResponse(
        status: 501, body: "clearAppData is simulator-only on iOS (devicectl has no equivalent;"
            + " reinstall the app instead)")

    /// **記憶した ft_install の path で reinstall する**: uninstall→install が撃たれ、
    /// launchedBundleIDs は ft_terminate と同じ扱いで消える(以後の木は「すり替わり」ではない)
    func testRememberedInstallPathReinstallsOnPhysicalDeviceRejection() async throws {
        driver.clearAppDataError = Self.physicalOnly501
        _ = try await server.call(tool: "ft_install", args: ["packagePath": "/tmp/A.app"])
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])

        let result = try await server.call(
            tool: "ft_clear_app_data", args: ["bundleId": "com.example.app"])
        let message = try XCTUnwrap(result.first?["text"] as? String)

        XCTAssertEqual(driver.calls, [
            "install(/tmp/A.app)", "launch(com.example.app)",
            "clearAppData(com.example.app)", "uninstall(com.example.app)", "install(/tmp/A.app)",
        ])
        XCTAssertTrue(message.contains("Reinstalled com.example.app from /tmp/A.app"), message)
        XCTAssertNil(server.launchedBundleIDs[key])
    }

    /// 明示 `packagePath` は事前の ft_install が無くても使える
    func testExplicitPackagePathIsUsedWithoutAPriorInstall() async throws {
        driver.clearAppDataError = Self.physicalOnly501
        let result = try await server.call(
            tool: "ft_clear_app_data",
            args: ["bundleId": "com.example.app", "packagePath": "/tmp/B.app"])
        let message = try XCTUnwrap(result.first?["text"] as? String)

        XCTAssertEqual(driver.calls, [
            "clearAppData(com.example.app)", "uninstall(com.example.app)", "install(/tmp/B.app)",
        ])
        XCTAssertTrue(message.contains("Reinstalled com.example.app from /tmp/B.app"), message)
    }

    /// 明示 `packagePath` は記憶より優先する(別ビルドを検証中に古い記憶へ黙って落ちない)
    func testExplicitPackagePathOverridesTheRememberedOne() async throws {
        driver.clearAppDataError = Self.physicalOnly501
        _ = try await server.call(tool: "ft_install", args: ["packagePath": "/tmp/A.app"])

        _ = try await server.call(
            tool: "ft_clear_app_data",
            args: ["bundleId": "com.example.app", "packagePath": "/tmp/B.app"])

        // ft_install 自身の install(/tmp/A.app) は残る。clear 側で撃たれたのが B だけであること
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("install(") },
                       ["install(/tmp/A.app)", "install(/tmp/B.app)"], "\(driver.calls)")
    }

    /// パスが無ければ(記憶も明示も)撃たずに packagePath を名指しして断る
    func testNeitherRememberedNorExplicitPathErrorsNamingPackagePath() async {
        driver.clearAppDataError = Self.physicalOnly501
        do {
            _ = try await server.call(
                tool: "ft_clear_app_data", args: ["bundleId": "com.example.app"])
            XCTFail("パスが無いのに成功した")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("packagePath"),
                          error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("uninstall(") || $0.hasPrefix("install(") },
                       "\(driver.calls)")
    }

    /// **501 以外は素通しする**(この経路は 501/simulator-only 専用の判定)
    func testANonMatchingErrorIsRethrownUnchanged() async {
        driver.clearAppDataError = DriverError.badResponse(status: 500, body: "boom")
        do {
            _ = try await server.call(
                tool: "ft_clear_app_data", args: ["bundleId": "com.example.app"])
            XCTFail("500 は素通しするはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("boom"), error.localizedDescription)
        }
    }

    /// 501 でも文言が simulator-only でなければ同じく素通しする(他の未対応機能の 501 と混同しない)
    func testA501WithADifferentBodyIsRethrownUnchanged() async {
        driver.clearAppDataError = DriverError.badResponse(status: 501, body: "not supported at all")
        do {
            _ = try await server.call(
                tool: "ft_clear_app_data", args: ["bundleId": "com.example.app"])
            XCTFail("simulator-only でない 501 は素通しするはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not supported at all"),
                          error.localizedDescription)
        }
    }
}
