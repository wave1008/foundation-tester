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
    private var tmpDir: URL!
    /// **reinstallSource は実在確認をする**(件2の修正)ので、再インストール元は実物を置く。
    /// 固定名だと並列実行で衝突するため、テストごとの一時ディレクトリに作る
    private var appA: String!
    private var appB: String!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-mcp-clearappdata-\(UUID().uuidString)")
        appA = tmpDir.appendingPathComponent("A.app").path
        appB = tmpDir.appendingPathComponent("B.app").path
        try? FileManager.default.createDirectory(atPath: appA, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: appB, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private static let physicalOnly501 = DriverError.badResponse(
        status: 501, body: "clearAppData is simulator-only on iOS (devicectl has no equivalent;"
            + " reinstall the app instead)")

    /// **記憶した ft_install の path で reinstall する**: uninstall→install が撃たれ、
    /// launchedBundleIDs は ft_terminate と同じ扱いで消える(以後の木は「すり替わり」ではない)
    func testRememberedInstallPathReinstallsOnPhysicalDeviceRejection() async throws {
        driver.clearAppDataError = Self.physicalOnly501
        _ = try await server.call(tool: "ft_install", args: ["packagePath": appA!])
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])

        let result = try await server.call(
            tool: "ft_clear_app_data", args: ["bundleId": "com.example.app"])
        let message = try XCTUnwrap(result.first?["text"] as? String)

        XCTAssertEqual(driver.calls, [
            "install(\(appA!))", "launch(com.example.app)",
            "clearAppData(com.example.app)", "uninstall(com.example.app)", "install(\(appA!))",
        ])
        XCTAssertTrue(message.contains("Reinstalled com.example.app from \(appA!)"), message)
        XCTAssertNil(server.launchedBundleIDs[key])
    }

    /// 明示 `packagePath` は事前の ft_install が無くても使える
    func testExplicitPackagePathIsUsedWithoutAPriorInstall() async throws {
        driver.clearAppDataError = Self.physicalOnly501
        let result = try await server.call(
            tool: "ft_clear_app_data",
            args: ["bundleId": "com.example.app", "packagePath": appB!])
        let message = try XCTUnwrap(result.first?["text"] as? String)

        XCTAssertEqual(driver.calls, [
            "clearAppData(com.example.app)", "uninstall(com.example.app)", "install(\(appB!))",
        ])
        XCTAssertTrue(message.contains("Reinstalled com.example.app from \(appB!)"), message)
    }

    /// 明示 `packagePath` は記憶より優先する(別ビルドを検証中に古い記憶へ黙って落ちない)
    func testExplicitPackagePathOverridesTheRememberedOne() async throws {
        driver.clearAppDataError = Self.physicalOnly501
        _ = try await server.call(tool: "ft_install", args: ["packagePath": appA!])

        _ = try await server.call(
            tool: "ft_clear_app_data",
            args: ["bundleId": "com.example.app", "packagePath": appB!])

        // ft_install 自身の install(appA) は残る。clear 側で撃たれたのが B だけであること
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("install(") },
                       ["install(\(appA!))", "install(\(appB!))"], "\(driver.calls)")
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

    // MARK: - 記憶したパスが既に消えている(実機で uninstall だけして戻せなくなる穴)

    /// **記憶したパスがディスクに無ければ uninstall 自体を撃たない**。再ビルドや DerivedData の
    /// 掃除で古いパスが消えることは普通に起きるので、確かめずに uninstall すると
    /// 「アプリだけ消えて入れ直せない」で終わる
    func testMissingRememberedPathRefusesWithoutUninstalling() async {
        driver.clearAppDataError = Self.physicalOnly501
        let missingPath = "/tmp/ft-reinstall-missing-\(UUID().uuidString)/A.app"
        _ = try? await server.call(tool: "ft_install", args: ["packagePath": missingPath])
        _ = try? await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])

        do {
            _ = try await server.call(
                tool: "ft_clear_app_data", args: ["bundleId": "com.example.app"])
            XCTFail("消えたパスなのに成功した")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("NOT uninstalled"),
                          error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(missingPath),
                          error.localizedDescription)
        }
        // install( はここまでに ft_install の1回だけ(clearAppData 側の再インストールは撃たれていない)
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("install(") }, ["install(\(missingPath))"],
                       "\(driver.calls)")
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("uninstall(") }, "\(driver.calls)")
    }

    /// 明示 `packagePath` が消えていても同じ(記憶があるかどうかに関係なく確かめる)
    func testMissingExplicitPathRefusesWithoutUninstalling() async {
        driver.clearAppDataError = Self.physicalOnly501
        let missingPath = "/tmp/ft-reinstall-missing-\(UUID().uuidString)/B.app"
        do {
            _ = try await server.call(
                tool: "ft_clear_app_data",
                args: ["bundleId": "com.example.app", "packagePath": missingPath])
            XCTFail("消えたパスなのに成功した")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("NOT uninstalled"),
                          error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("uninstall(") || $0.hasPrefix("install(") },
                       "\(driver.calls)")
    }

    // MARK: - reinstallSource(純粋関数)

    /// 明示 packagePath が記憶より優先される(exists は両方 true でも explicit を選ぶこと)
    func testReinstallSourcePrefersExplicitOverRemembered() {
        let result = MCPServer.reinstallSource(
            explicit: "/tmp/explicit.app", remembered: "/tmp/remembered.app", exists: { _ in true })
        XCTAssertEqual(try? result.get(), "/tmp/explicit.app")
    }

    /// 明示が無ければ記憶を使う
    func testReinstallSourceFallsBackToRememberedWhenNoExplicitPath() {
        let result = MCPServer.reinstallSource(
            explicit: nil, remembered: "/tmp/remembered.app", exists: { _ in true })
        XCTAssertEqual(try? result.get(), "/tmp/remembered.app")
    }

    /// どちらも無ければ packagePath を名指しして断る(exists は呼ばれない = uninstall 前の
    /// 最初のガードで止まっていること)
    func testReinstallSourceFailsNamingPackagePathWhenNeitherIsGiven() {
        var existsCalled = false
        let result = MCPServer.reinstallSource(
            explicit: nil, remembered: nil, exists: { _ in existsCalled = true; return true })
        guard case .failure(let error) = result else { return XCTFail("成功するはずがない") }
        XCTAssertTrue(error.message.contains("packagePath"), error.message)
        XCTAssertFalse(existsCalled)
    }

    /// パスはあるが実在しない(消えた)ときは「アンインストールしていない」ことと
    /// パスそのものを名指しして断る
    func testReinstallSourceFailsWhenTheResolvedPathDoesNotExist() {
        let result = MCPServer.reinstallSource(
            explicit: "/tmp/gone.app", remembered: nil, exists: { _ in false })
        guard case .failure(let error) = result else { return XCTFail("成功するはずがない") }
        XCTAssertTrue(error.message.contains("NOT uninstalled"), error.message)
        XCTAssertTrue(error.message.contains("/tmp/gone.app"), error.message)
    }
}
