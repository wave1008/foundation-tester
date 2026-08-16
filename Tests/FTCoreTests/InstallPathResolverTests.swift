// installApp() RPC の親側パス解決(明示引数 > プロファイルの appPath)を実機無しで固定する
import XCTest
@testable import FTCore

final class InstallPathResolverTests: XCTestCase {

    private func apps(appPath: String? = "/Apps/App.app", bundleID: String = "com.example.app")
        -> [String: ResolvedAppTarget] {
        ["ios": ResolvedAppTarget(bundleID: bundleID, appPath: appPath)]
    }

    func testExplicitPathWinsOverProfileAppPath() {
        let resolution = InstallPathResolver.resolve(
            platform: "ios", explicitPath: "/explicit/App.app",
            apps: apps(appPath: "/profile/App.app"), fileExists: { _ in true })
        XCTAssertEqual(resolution, .resolved(path: "/explicit/App.app", bundleID: "com.example.app"))
    }

    func testFallsBackToProfileAppPathWhenExplicitIsNil() {
        let resolution = InstallPathResolver.resolve(
            platform: "ios", explicitPath: nil,
            apps: apps(appPath: "/profile/App.app"), fileExists: { _ in true })
        XCTAssertEqual(resolution, .resolved(path: "/profile/App.app", bundleID: "com.example.app"))
    }

    func testExpandsTildeInExplicitPath() {
        let home = NSHomeDirectory()
        var seen: String?
        let resolution = InstallPathResolver.resolve(
            platform: "ios", explicitPath: "~/App.app", apps: apps(appPath: nil),
            fileExists: { path in seen = path; return true })
        XCTAssertEqual(seen, home + "/App.app")
        XCTAssertEqual(resolution, .resolved(path: home + "/App.app", bundleID: "com.example.app"))
    }

    func testErrorWhenNoAppConfiguredForPlatform() {
        let resolution = InstallPathResolver.resolve(
            platform: "android", explicitPath: "/explicit/App.apk",
            apps: apps(), fileExists: { _ in true })
        guard case .error(let message) = resolution else {
            return XCTFail("android 未設定なのに error にならなかった")
        }
        XCTAssertTrue(message.contains("no app is configured"), message)
    }

    func testErrorWhenNeitherExplicitNorProfileHasAPath() {
        let resolution = InstallPathResolver.resolve(
            platform: "ios", explicitPath: nil, apps: apps(appPath: nil), fileExists: { _ in true })
        guard case .error(let message) = resolution else {
            return XCTFail("パス無しなのに error にならなかった")
        }
        XCTAssertTrue(message.contains("no package path was given"), message)
    }

    func testErrorWhenResolvedPathDoesNotExist() {
        let resolution = InstallPathResolver.resolve(
            platform: "ios", explicitPath: "/nope/App.app", apps: apps(), fileExists: { _ in false })
        guard case .error(let message) = resolution else {
            return XCTFail("存在しないパスなのに error にならなかった")
        }
        XCTAssertTrue(message.contains("package not found"), message)
        XCTAssertTrue(message.contains("/nope/App.app"), message)
    }
}
