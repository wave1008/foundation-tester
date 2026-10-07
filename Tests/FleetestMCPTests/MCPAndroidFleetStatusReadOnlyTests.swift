// ft_status の Android 複数台の一覧は読むだけ。`AndroidDriver.status()` は動いていないブリッジを起動まで撃つ
// (APK の導入・force-stop・アニメ無効化)ので、一覧で全台へ撃つと他のセッションの端末のブリッジまで作り直す

import XCTest

final class MCPAndroidFleetStatusReadOnlyTests: XCTestCase {

    func testFleetListingNeverStartsABridge() throws {
        let code = try MCPServerSourceText.combined()
        let start = try XCTUnwrap(code.range(of: "static func androidFleetStatus("))
        let body = String(code[start.upperBound...].prefix(1500))
        let end = body.range(of: "\n    }\n")?.lowerBound ?? body.endIndex
        let listing = body[..<end]
        XCTAssertTrue(listing.contains("statusIfBridgeRunning()"), "一覧は起動しない照会を使うこと")
        XCTAssertFalse(listing.contains("driver.status()"), "一覧で status() を撃つとブリッジを起動する")
    }
}
