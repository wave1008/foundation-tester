// シナリオ経路の InAppDriver は、dylib を注入するアプリ(`ownBundleID`)と違うアプリの launch を断る。
// 断らないと別アプリへ同じ FT_PORT で注入して起動し、ポートを取り合った旧ブリッジが答えて裏のアプリを操作した。
// 別アプリの手順は @TestClass(app:) の別シナリオへ(注入先と違うシナリオは丸ごと XCUITest で動く)。
// **実際の注入起動は撃たない**(simctl を呼ぶ = ホストの共有資源)ので、断りは launcher より前で返ることだけを見る

import XCTest
import FTCore
@testable import FTBridgeClient

final class InAppDriverForeignLaunchTests: XCTestCase {

    func testLaunchingAnotherAppIsRefusedBeforeInjecting() async {
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: "/nonexistent-ft"), udid: "UDID-1", port: 1,
                                 ownBundleID: "com.example.sut")
        do {
            try await driver.launch(bundleID: "com.apple.Preferences")
            XCTFail("別アプリの launch が断られていない")
        } catch let DriverError.badResponse(status, body) {
            XCTAssertEqual(status, 422)
            XCTAssertTrue(body.contains("@TestClass(app: \"com.apple.Preferences\")"), body)
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    /// 自分のアプリと、ownBundleID を渡さない呼び手(ライブ操作)は断らない
    func testOwnAppAndCallersWithoutAnOwnAppAreNotRefused() {
        XCTAssertNil(InAppDriver.foreignLaunchRefusal(bundleID: "com.example.sut", own: "com.example.sut"))
        XCTAssertNil(InAppDriver.foreignLaunchRefusal(bundleID: "com.apple.Preferences", own: nil))
        XCTAssertNotNil(InAppDriver.foreignLaunchRefusal(bundleID: "com.apple.Preferences", own: "com.example.sut"))
    }
}
