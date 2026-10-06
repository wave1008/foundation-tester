// AndroidDriver.activate の失敗文言(monkey の引数エコーを落とす)。出力は emulator で実際に採った形
// (2026-10-06・未インストールの package を monkey -p で起動)。

import XCTest
@testable import FTAndroid

final class MonkeyFailureDetailTests: XCTestCase {

    private let notInstalled = """
          bash arg: -p
          bash arg: com.not.installed.zz
          bash arg: -c
          bash arg: android.intent.category.LAUNCHER
          bash arg: 1
        args: [-p, com.not.installed.zz, -c, android.intent.category.LAUNCHER, 1]
         arg: "-p"
         arg: "com.not.installed.zz"
         arg: "-c"
         arg: "android.intent.category.LAUNCHER"
         arg: "1"
        data="com.not.installed.zz"
        data="android.intent.category.LAUNCHER"
        ** No activities found to run, monkey aborted.
        """

    /// 理由の1行だけが残る(引数のエコーは1行も残らない)
    func testKeepsOnlyTheReasonLine() {
        XCTAssertEqual(AndroidDriver.monkeyFailureDetail(notInstalled),
                       "** No activities found to run, monkey aborted.")
    }

    /// エコーしか無い出力(途中で切れた等)は理由を作らず、元の出力をそのまま返す
    func testFallsBackToTheRawOutputWhenOnlyEchoRemains() {
        let echoOnly = "  bash arg: -p\nargs: [-p]\n arg: \"-p\""
        XCTAssertEqual(AndroidDriver.monkeyFailureDetail(echoOnly), echoOnly)
    }

    /// adb 自体の失敗(monkey が動いていない)はそのまま通す
    func testPassesThroughAdbErrors() {
        XCTAssertEqual(AndroidDriver.monkeyFailureDetail("adb: device offline"), "adb: device offline")
    }
}
