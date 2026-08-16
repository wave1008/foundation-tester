// AndroidDriver.openURL の純粋ロジック(am start の引数構築・失敗判定)。デバイスなしで固定する。
// adb shell はクライアント側の複数引数を空白結合してからデバイス側シェルへ渡すため、URL に含まれる
// `&`/`?` 等がシェルへ筒抜けにならないよう自前でシングルクォート引用する(quoteURLForDeviceShell)。

import XCTest
@testable import FTAndroid
import FTCore

final class AndroidOpenURLTests: XCTestCase {

    // MARK: - quoteURLForDeviceShell

    func testPlainURLIsSingleQuoted() throws {
        let quoted = try AndroidDriver.quoteURLForDeviceShell("fte2e://screen/detail")
        XCTAssertEqual(quoted, "'fte2e://screen/detail'")
    }

    /// `&` を含む URL がクォートを経ずにデバイスシェルへ渡ると、そこでコマンドが切れて
    /// 後続のパラメータが独立コマンドとして解釈されてしまう(実害の対象そのもの)
    func testURLWithAmpersandAndQuestionMarkIsQuoted() throws {
        let quoted = try AndroidDriver.quoteURLForDeviceShell("fte2e://screen/lifecycle?tag=a&n=1")
        XCTAssertEqual(quoted, "'fte2e://screen/lifecycle?tag=a&n=1'")
    }

    /// URL 自体にシングルクォートが入っていると引用が壊れる(閉じクォートが早まる)。
    /// 黙って壊れたコマンドを組み立てず throw する
    func testURLContainingSingleQuoteThrows() {
        XCTAssertThrowsError(try AndroidDriver.quoteURLForDeviceShell("fte2e://screen?name=o'brien")) { error in
            guard case DriverError.badResponse(let status, let body) = error else {
                return XCTFail("DriverError.badResponse ではない: \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("single quote"), body)
        }
    }

    // MARK: - amStartArgs

    func testAmStartArgsWithoutPackage() throws {
        let args = try AndroidDriver.amStartArgs(url: "fte2e://screen/detail", package: nil)
        XCTAssertEqual(args, ["shell", "am", "start", "-W", "-a", "android.intent.action.VIEW",
                              "-d", "'fte2e://screen/detail'"])
    }

    /// package は bundleID が非 nil のときだけ付ける(付けないとチューザ/ブラウザへ流れる)
    func testAmStartArgsWithPackageAppendsItLast() throws {
        let args = try AndroidDriver.amStartArgs(url: "fte2e://screen/detail",
                                                 package: "com.ftester.e2e.android")
        XCTAssertEqual(args, ["shell", "am", "start", "-W", "-a", "android.intent.action.VIEW",
                              "-d", "'fte2e://screen/detail'", "com.ftester.e2e.android"])
    }

    func testAmStartArgsPropagatesQuoteFailure() {
        XCTAssertThrowsError(try AndroidDriver.amStartArgs(url: "fte2e://x?n='y'", package: nil))
    }

    // MARK: - amStartIndicatesFailure

    func testSuccessfulOutputDoesNotIndicateFailure() {
        XCTAssertFalse(AndroidDriver.amStartIndicatesFailure(
            output: "Starting: Intent { act=android.intent.action.VIEW dat=fte2e://screen/detail }"))
    }

    /// am start は失敗しても exit 0 で stdout に "Error:" を出すことがある(意図解決失敗等)
    func testErrorPrefixIndicatesFailure() {
        XCTAssertTrue(AndroidDriver.amStartIndicatesFailure(
            output: "Starting: Intent { ... }\nError: Activity not started, unable to resolve Intent"))
    }

    /// **成功の出力**(2026-08-08 に E2EAppFlutter / E2EAppRN の実機ならぬ Emulator 上で実測)。
    /// singleTop の SUT では warm 配送の通常応答がこれで、失敗と読むと配送が全滅する
    func testDeliveredToTopMostInstanceIsSuccess() {
        XCTAssertFalse(AndroidDriver.amStartIndicatesFailure(
            output: "Starting: Intent { act=android.intent.action.VIEW dat=fte2e://screen/lifecycle"
                + " pkg=com.ftester.e2e.flutter }\n"
                + "Warning: Activity not started, intent has been delivered to currently running"
                + " top-most instance."))
    }
}
