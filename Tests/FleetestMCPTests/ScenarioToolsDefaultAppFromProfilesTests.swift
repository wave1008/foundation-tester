// `MCPServer.defaultAppFromProjectApps` — profile 引数の無い ft_run_scenario 呼び出しで、
// @TestClass(app:) を書いていないシナリオの既定アプリをプロジェクトのアプリプロファイル
// (profiles/apps/*.json)から解決する判定(ディスク走査(loadAppProfiles)から切り出した純粋関数)。
// この解決が無いと、profile を付けずに「今自分が駆動している台」でシナリオを回す手段が無く、
// 案内どおり profile を足すと今度は「profile は udid と併用できない」で行き止まりになっていた。

import XCTest
import FTCore
@testable import fleetest_mcp

final class ScenarioToolsDefaultAppFromProfilesTests: XCTestCase {

    private func section(app: String? = nil, appName: String? = nil,
                         appPath: String? = nil) -> AppProfileSection {
        AppProfileSection(appName: appName, app: app, appPath: appPath)
    }

    /// ちょうど1つのアプリプロファイルが対象 platform の欄を持っていれば、それを採る
    func testExactlyOneAppProfileIsAdopted() {
        let profile = AppProfile(ios: section(app: "com.example.app", appName: "Example",
                                              appPath: "TestProjects/E2E-CMP/dist/ios/App.app"))
        let result = MCPServer.defaultAppFromProjectApps([(name: "main", profile: profile)],
                                                          platform: "ios")
        XCTAssertEqual(result, .resolved(profileName: "main", bundleID: "com.example.app",
                                         appName: "Example",
                                         appPath: "TestProjects/E2E-CMP/dist/ios/App.app"))
    }

    /// 複数あるときは黙って選ばず、名前を並べて断る(順序はそのまま渡した順)
    func testMultipleAppProfilesAreRefusedByName() {
        let a = AppProfile(ios: section(app: "com.example.a"))
        let b = AppProfile(ios: section(app: "com.example.b"))
        let result = MCPServer.defaultAppFromProjectApps(
            [(name: "a", profile: a), (name: "b", profile: b)], platform: "ios")
        XCTAssertEqual(result, .ambiguous(profileNames: ["a", "b"]))
    }

    /// 唯一のプロファイルに対象 platform の欄が無い(例: iOS 用シナリオなのに android 欄しか無い)
    /// ときは「解決できなかった」として扱う(黙って別 platform の bundleID を借用しない)
    func testSingleProfileMissingThePlatformSectionIsUnresolved() {
        let profile = AppProfile(android: section(app: "com.example.android"))
        let result = MCPServer.defaultAppFromProjectApps([(name: "main", profile: profile)],
                                                          platform: "ios")
        XCTAssertEqual(result, .none)
    }

    /// アプリプロファイルが1つも無ければ従来どおり(ScenarioAppResolution の文言に任せる)
    func testNoAppProfilesIsUnresolved() {
        XCTAssertEqual(MCPServer.defaultAppFromProjectApps([], platform: "ios"), .none)
    }

    /// 欄はあっても bundleID(app)が空文字列なら「無い」と同じ扱い
    func testEmptyBundleIDInTheOnlyProfileIsUnresolved() {
        let profile = AppProfile(ios: section(app: ""))
        let result = MCPServer.defaultAppFromProjectApps([(name: "main", profile: profile)],
                                                          platform: "ios")
        XCTAssertEqual(result, .none)
    }

    // MARK: - 曖昧なときに断るのは、既定アプリを使うシナリオがあるときだけ

    func testAmbiguousDefaultAppIsNoReasonToRefuseWhenEveryScenarioNamesItsApp() {
        let infos = [ScenarioInfo(id: "A.S0010", title: "", app: "com.example.a", platform: "ios"),
                     ScenarioInfo(id: "A.S0020", title: "", app: "com.example.a", platform: "ios")]
        XCTAssertNil(MCPServer.ambiguousDefaultAppRefusal(profileNames: ["x", "y"], infos: infos))
    }

    func testAmbiguousDefaultAppRefusesWhenAScenarioNeedsTheDefault() throws {
        let infos = [ScenarioInfo(id: "A.S0010", title: "", app: "com.example.a", platform: "ios"),
                     ScenarioInfo(id: "A.S0020", title: "", app: nil, platform: "ios")]
        let refusal = try XCTUnwrap(
            MCPServer.ambiguousDefaultAppRefusal(profileNames: ["x", "y"], infos: infos))
        XCTAssertTrue(refusal.contains("x, y"), refusal)
    }
}
