// run 開始時に縦向きでない iOS のデバイスを警告する(ProfileWorkerFactory.warnOnNonPortraitIOS)。
// 横向きのまま残った Simulator で、縦向き前提のシナリオが「見つからない」で落ちた(同じ台で2回)。

import XCTest
@testable import FTCore
@testable import FTAndroid

final class NonPortraitWarningTests: XCTestCase {

    func testLandscapeIsWarnedWithTheDeviceName() throws {
        let line = try XCTUnwrap(ProfileWorkerFactory.nonPortraitWarning(
            label: "iPhone 17 Pro(iOS 27.0)-08(ios:8146)", orientation: .landscape))
        XCTAssertTrue(line.contains("iPhone 17 Pro(iOS 27.0)-08"), line)
        XCTAssertTrue(line.contains("landscape"), line)
    }

    func testPortraitAndUnknownAreSilent() {
        XCTAssertNil(ProfileWorkerFactory.nonPortraitWarning(label: "d", orientation: .portrait))
        XCTAssertNil(ProfileWorkerFactory.nonPortraitWarning(label: "d", orientation: nil),
                     "読めない台は黙って飛ばす(不明を警告にしない)")
    }

    /// 開始時の準備(3つの供給口が共有する1箇所)から呼ばれていること
    func testRunStartPreparationCallsTheCheck() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let start = text.range(of: "public static func prepareDevicesOnStart("),
              let end = text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex)
        else { return XCTFail("prepareDevicesOnStart が見つからない") }
        XCTAssertTrue(text[start.lowerBound..<end.upperBound].contains("await warnOnNonPortraitIOS(workers, log: log)"))
        XCTAssertTrue(text[start.lowerBound..<end.upperBound].contains("await warnOnNonPortraitAndroid(workers, log: log)"))
    }

    // 実測(Emulator, 1080x2424): 縦 cur=1080x2424 / user_rotation=1 の横 cur=2424x1080
    func testAndroidOrientationFromDumpsysCur() {
        let head = "    init=1080x2424 420dpi mMinSizeOfResizeableTaskDp=220 cur="
        XCTAssertEqual(ProfileWorkerFactory.androidOrientation(fromDumpsysWindow: head + "1080x2424 app=1080x2424"), .portrait)
        XCTAssertEqual(ProfileWorkerFactory.androidOrientation(fromDumpsysWindow: head + "2424x1080 app=2424x1080"), .landscape)
        XCTAssertNil(ProfileWorkerFactory.androidOrientation(fromDumpsysWindow: ""))
        XCTAssertNil(ProfileWorkerFactory.androidOrientation(fromDumpsysWindow: "no display info"))
        XCTAssertNil(ProfileWorkerFactory.androidOrientation(fromDumpsysWindow: head + "1080x1080 app=1080x1080"))
    }

    // 実測(Android 16 の Emulator): 横に固定した台はホーム(縦固定のランチャー)が前面だと cur が縦のまま。固定の向きを採る
    func testAndroidLockedRotationWinsOverCurrentSize() {
        let portraitCur = "    init=1080x2424 420dpi cur=1080x2424 app=1080x2424\n"
        let lock = { (mode: String, degrees: Int) in
            portraitCur + "    mUserRotationMode=\(mode) mUserRotation=ROTATION_\(degrees) mCameraRotationMode=0"
        }
        XCTAssertEqual(ProfileWorkerFactory.androidOrientation(fromDumpsysWindow: lock("USER_ROTATION_LOCKED", 90)), .landscape)
        XCTAssertEqual(ProfileWorkerFactory.androidOrientation(fromDumpsysWindow: lock("USER_ROTATION_LOCKED", 270)), .landscape)
        XCTAssertEqual(ProfileWorkerFactory.androidOrientation(fromDumpsysWindow: lock("USER_ROTATION_LOCKED", 0)), .portrait)
        // 自動回転(FREE)は固定の値を見ず、表示の寸法に従う
        XCTAssertEqual(ProfileWorkerFactory.androidOrientation(fromDumpsysWindow: lock("USER_ROTATION_FREE", 90)), .portrait)
    }
}
