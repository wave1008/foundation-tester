// --host-install(installApp() の実行先)と --app-path(バンドルの在処)が
// **排他ではない**ことの固定。排他に戻すと実機で uiFrameworkHint が決まらず、
// スクロール探索後の空打ちドラッグが盲撃ちになる(RN で行を選ぶ)。
import XCTest
@testable import FTCore

final class ScenarioHostInstallArgumentsTests: XCTestCase {

    func testHostInstallStillCarriesTheBundlePath() {
        let args = ScenarioHost.installArguments(hostInstall: true, appPath: "/tmp/A.app")
        XCTAssertTrue(args.contains("--host-install"))
        guard let index = args.firstIndex(of: "--app-path") else {
            return XCTFail("--app-path was dropped when the host performs the install: \(args)")
        }
        XCTAssertEqual(args[args.index(after: index)], "/tmp/A.app")
    }

    func testChildInstallPathWithoutHostInstall() {
        XCTAssertEqual(ScenarioHost.installArguments(hostInstall: false, appPath: "/tmp/A.app"),
                       ["--app-path", "/tmp/A.app"])
    }

    func testNoBundlePathAvailable() {
        XCTAssertEqual(ScenarioHost.installArguments(hostInstall: true, appPath: nil),
                       ["--host-install"])
        XCTAssertEqual(ScenarioHost.installArguments(hostInstall: false, appPath: nil), [])
    }
}
