// pm path によるブリッジ APK の健全性判定(AndroidDriver.codePathVerdict)。
// witness: pm list packages -u / dumpsys にはレコードが残るのに pm path が空、という
// 中途半端な install(受け手報告 2026-08-24。revive では直らず pm uninstall で回復)。

import XCTest
@testable import FTAndroid

final class BridgeCodePathVerdictTests: XCTestCase {
    private let marker = AndroidDriver.pmPathMarker

    func testPackageLinePresentMeansHealthy() {
        XCTAssertEqual(AndroidDriver.codePathVerdict(
            output: "package:/data/app/~~abc==/com.example.ftbridge-xyz==/base.apk\n\(marker)\n",
            status: 0), true)
    }

    func testMarkerOnlyMeansBrokenInstall() {
        XCTAssertEqual(AndroidDriver.codePathVerdict(output: "\(marker)\n", status: 0), false)
    }

    // pm path は未インストールでも非0で終わりうるため、マーカーが返らない・status 非0 は
    // 「adb 不調 = 判定不能」。false と混同すると健全な端末を剥がして入れ直す
    func testMissingMarkerOrBadStatusIsInconclusive() {
        XCTAssertNil(AndroidDriver.codePathVerdict(output: "", status: 0))
        XCTAssertNil(AndroidDriver.codePathVerdict(output: "adb: device offline", status: 1))
        XCTAssertNil(AndroidDriver.codePathVerdict(output: "\(marker)\n", status: 1))
    }

    // shell の echo は行頭に空白を足さないが、行の正規化で package: 行を落とさないことを固定
    func testIndentedPackageLineStillCounts() {
        XCTAssertEqual(AndroidDriver.codePathVerdict(
            output: "  package:/data/app/base.apk\n\(marker)\n", status: 0), true)
    }
}
