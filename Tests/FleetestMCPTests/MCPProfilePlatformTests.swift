// `profile:` だけを渡した呼び出しの platform 解決。driver() は resolveProfileTarget で Android の
// 台に解決するのに、platformName が既定の iOS を返していた —— ft_list_apps が simctl へ落ち、
// ft_rotate / ft_logs / verifiedRef が iOS 側の記録・言い回しになる。
// プロジェクトは FT_PACKAGE_ROOT(ScenarioHost.packageRoot が cwd 探索より優先)で一時ディレクトリへ
// 差し替える。env はプロセス全体の状態なので必ず戻す。

import XCTest
@testable import fleetest_mcp

final class MCPProfilePlatformTests: XCTestCase {
    private var root: URL!
    private var savedRoot: String?
    private var savedMachine: String?

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MCPProfilePlatformTests-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("TestProjects/p/profiles")
        for sub in ["runs", "machines", "apps"] {
            try FileManager.default.createDirectory(
                at: profiles.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "// swift-tools-version:5.9\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try #"{"android":{"devices":[{"name":"Emu","avd":"Pixel_9"}]},"ios":{"devices":[{"name":"Sim","simulator":"iPhone 17"}]}}"#
            .write(to: profiles.appendingPathComponent("machines/local.json"), atomically: true, encoding: .utf8)
        try #"{"app":"app","machine":"local","devices":[{"name":"Emu"}]}"#
            .write(to: profiles.appendingPathComponent("runs/android-run.json"), atomically: true, encoding: .utf8)
        try #"{"app":"app","machine":"local","devices":[{"name":"Sim"}]}"#
            .write(to: profiles.appendingPathComponent("runs/ios-run.json"), atomically: true, encoding: .utf8)
        try #"{"app":"app","machine":"local","devices":[{"name":"Emu"},{"name":"Sim"}]}"#
            .write(to: profiles.appendingPathComponent("runs/mixed-run.json"), atomically: true, encoding: .utf8)

        savedRoot = ProcessInfo.processInfo.environment["FT_PACKAGE_ROOT"]
        savedMachine = ProcessInfo.processInfo.environment["FT_MACHINE"]
        setenv("FT_PACKAGE_ROOT", root.path, 1)
        unsetenv("FT_MACHINE")
    }

    override func tearDownWithError() throws {
        if let savedRoot { setenv("FT_PACKAGE_ROOT", savedRoot, 1) } else { unsetenv("FT_PACKAGE_ROOT") }
        if let savedMachine { setenv("FT_MACHINE", savedMachine, 1) }
        try? FileManager.default.removeItem(at: root)
    }

    /// 本丸: Android の台だけを持つ実行プロファイルを profile: で名指しすると android
    func testProfileWithAndroidDevicesResolvesToAndroid() {
        XCTAssertEqual(MCPServer.platformName(["profile": "android-run"]), "android")
        XCTAssertEqual(MCPServer.platformName(["profile": "android-run", "project": "p"]), "android")
    }

    func testProfileWithIOSDevicesResolvesToIOS() {
        XCTAssertEqual(MCPServer.platformName(["profile": "ios-run"]), "ios")
    }

    /// 混在プロファイルは **最初の台**(resolveProfileTarget の `devices.first` と同じ規則)
    func testMixedProfileFollowsTheFirstDevice() {
        XCTAssertEqual(MCPServer.platformName(["profile": "mixed-run"]), "android")
    }

    /// 明示 platform と明示ターゲットはプロファイルより勝つ(既存の優先順を変えない)
    func testExplicitPlatformAndTargetsStillWin() {
        XCTAssertEqual(MCPServer.platformName(["profile": "android-run", "platform": "ios"]), "ios")
        XCTAssertEqual(MCPServer.platformName(["profile": "android-run", "port": 8123]), "ios")
        XCTAssertEqual(MCPServer.platformName(["profile": "ios-run", "serial": "emulator-5554"]), "android")
    }

    /// 読めないプロファイル/プロジェクトは既定へ落ちる(driver() が改めて明確なエラーを出す)
    func testUnknownProfileFallsBackToTheDefault() {
        XCTAssertEqual(MCPServer.platformName(["profile": "no-such-run"]), "ios")
        XCTAssertEqual(MCPServer.platformName(["profile": "android-run", "project": "no-such-project"]), "ios")
        XCTAssertNil(MCPServer.profilePlatform(profile: "no-such-run", project: nil))
    }

    /// **ドライバが手元にある呼び手はドライバの型で決める**(ファイルを読み直さない)。
    /// ft_list_apps / ft_launch / ft_rotate / ft_double_tap は driver() を通した直後なので、
    /// platformName(args) ではなく `is AndroidDriver` で分岐していること
    func testCallSitesWithADriverAtHandDecideByTheDriverType() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Dispatch.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("if let android = appsDriver as? AndroidDriver {"), "ft_list_apps")
        XCTAssertTrue(code.contains("platform: launchDriver is AndroidDriver ? \"android\" : \"ios\""), "ft_launch")
        XCTAssertTrue(code.contains("recordSnapshot(rotated, rotateDriver is AndroidDriver ? \"android\" : \"ios\", args)"),
                      "ft_rotate")
        XCTAssertTrue(code.contains("isAndroid: doubleTapDriver is AndroidDriver)"), "ft_double_tap")
    }
}
