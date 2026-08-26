// appPathPhysical(実機に配るパッケージ)の規則の固定。
// 端末ごとにアプリプロファイルを分けないための欄なので、**種別で選び分かれること**と
// **ステージング先が衝突しないこと**の2つが要点。
import XCTest
@testable import FTCore

final class PhysicalAppPathTests: XCTestCase {

    private func target(appPath: String?, physicalPath: String?) -> ResolvedAppTarget {
        ResolvedAppTarget(bundleID: "com.example.app", appPath: appPath,
                          appPathPhysical: physicalPath)
    }

    func testPhysicalDeviceGetsTheDeviceBuild() {
        let app = target(appPath: "/b/sim/A.app", physicalPath: "/b/dev/A.app")
        XCTAssertEqual(app.packagePath(physical: true), "/b/dev/A.app")
        XCTAssertEqual(app.packagePath(physical: false), "/b/sim/A.app")
    }

    /// Android は同じ APK が両方で動くので、書かれていなければ appPath に落ちるのが正しい
    func testFallsBackToAppPathWhenNotDeclared() {
        let app = target(appPath: "/b/app.apk", physicalPath: nil)
        XCTAssertEqual(app.packagePath(physical: true), "/b/app.apk")
    }

    /// 同名の2ビルド(dist/ios-simulator/X.app と dist/ios-device/X.app)を同じ apps/ へ
    /// 置くと上書きし合い、片方の端末に必ず誤ったビルドが入る
    func testStagingDestinationsDoNotCollide() {
        let root = URL(fileURLWithPath: "/w")
        let sim = WorkspaceAppStaging.installPath(source: "/b/ios-simulator/X.app",
                                                  workspaceRoot: root)
        let dev = WorkspaceAppStaging.installPath(source: "/b/ios-device/X.app",
                                                  workspaceRoot: root, physical: true)
        XCTAssertNotEqual(sim, dev)
        XCTAssertEqual(sim, "/w/apps/X.app")
        XCTAssertEqual(dev, "/w/apps/physical/X.app")
    }

    /// installApp() の親側解決(RPC)も同じ規則を通る
    func testInstallPathResolverPicksTheDeviceBuild() {
        let apps = ["ios": target(appPath: "/b/sim/A.app", physicalPath: "/b/dev/A.app")]
        let resolution = InstallPathResolver.resolve(
            platform: "ios", explicitPath: nil, apps: apps, physical: true,
            fileExists: { $0 == "/b/dev/A.app" })
        XCTAssertEqual(resolution, .resolved(path: "/b/dev/A.app", bundleID: "com.example.app"))
    }

    /// 明示引数(installApp("...") の path)は種別より強い
    func testExplicitPathStillWins() {
        let apps = ["ios": target(appPath: "/b/sim/A.app", physicalPath: "/b/dev/A.app")]
        let resolution = InstallPathResolver.resolve(
            platform: "ios", explicitPath: "/tmp/Other.app", apps: apps, physical: true,
            fileExists: { _ in true })
        XCTAssertEqual(resolution, .resolved(path: "/tmp/Other.app", bundleID: "com.example.app"))
    }
}
