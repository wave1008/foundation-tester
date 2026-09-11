// 全レーン復活不能のとき、最後の発話が原因(FATAL)ではなく
// 「devices up で起動しろ」と誤誘導していた。復活に失敗していた AVD なら、その理由を
// avdNotRunning のメッセージへ引き継ぐ。adb を叩かない部分(AndroidDeviceCatalog.avdNotRunningError)
// だけを直接叩く — resolveSerial 自体はデバイス無しではテストできない。

import XCTest
@testable import FTAndroid

final class AndroidDeviceCatalogAvdNotRunningTests: XCTestCase {

    func testMentionsDevicesUpWhenNoRevivalWasAttempted() {
        let error = AndroidDeviceCatalog.avdNotRunningError(
            avd: "Pixel_9_Android_15_-01", canonical: "Pixel_9_Android_15_-01",
            running: [:], revivalFailure: nil)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("fleetest devices up"), message)
    }

    /// 復活を試みて失敗していたなら、その理由を言う。「devices up」を案内しない
    /// (この run は既にそれをやろうとして失敗している)
    func testUsesTheRevivalFailureReasonInstead() {
        let error = AndroidDeviceCatalog.avdNotRunningError(
            avd: "Pixel_9_Android_15_-01", canonical: "Pixel_9_Android_15_-01",
            running: [:],
            revivalFailure: "the emulator exited before it registered with adb"
                + " — its own log says: FATAL | Broken AVD system path")
        let message = error.errorDescription ?? ""
        XCTAssertFalse(message.contains("fleetest devices up"), message)
        XCTAssertTrue(message.contains("Broken AVD system path"), message)
    }

    func testLabelsTheAvdWithItsCanonicalIdWhenTheyDiffer() {
        let error = AndroidDeviceCatalog.avdNotRunningError(
            avd: "Pixel 9(Android 15)", canonical: "Pixel_9_Android_15_",
            running: [:], revivalFailure: nil)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("Pixel 9(Android 15)(ID: Pixel_9_Android_15_)"), message)
    }
}
