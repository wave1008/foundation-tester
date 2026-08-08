// pressEnter がブリッジで失敗したあとの分岐。**409 は2種類ある**のが要点:
// 「IME アクションが失敗」はキーイベントで救えるが、「入力フォーカスが無い」は誰も受け取らない。
// 後者を素通しすると、入力欄のタップに失敗したまま Enter が「成功」し、検索が実行されないまま
// 後段の検証でだけ落ちる(2026-08-07 に Google マップで実測した沈黙した誤り)。

import XCTest
@testable import FTAndroid
import FTCore

final class PressEnterFallbackTests: XCTestCase {

    /// **フォーカス無しの 409 は止める**(キーイベントへ落とさず、原因を名指しして投げる)
    func testNoFocus409Aborts() {
        let abort = AndroidDriver.pressEnterAbort(after: .badResponse(
            status: 409, body: "no-input-focus: nothing has input focus (tap the field by ref first)"))
        guard case .badResponse(let status, let body)? = abort else {
            return XCTFail("止めていない(フォールバックへ落ちる)")
        }
        XCTAssertEqual(status, 409)
        XCTAssertTrue(body.contains("no field has input focus"), body)
        XCTAssertTrue(body.contains("Tap the field by ref first"), body)
    }

    /// **IME アクション失敗の 409 はフォールバック**(キーイベントで救える)
    func testImeFailure409FallsBack() {
        XCTAssertNil(AndroidDriver.pressEnterAbort(after: .badResponse(
            status: 409, body: "the IME Enter action could not be performed")))
    }

    /// 旧ブリッジ(404)と API 30 未満(501)もフォールバック
    func testUnsupportedStatusesFallBack() {
        XCTAssertNil(AndroidDriver.pressEnterAbort(after: .badResponse(status: 404, body: "not found")))
        XCTAssertNil(AndroidDriver.pressEnterAbort(after: .badResponse(
            status: 501, body: "ACTION_IME_ENTER is not supported below API 30")))
    }

    /// それ以外(500 等)は握り潰さずそのまま投げる
    func testOtherErrorsPropagate() {
        let original = DriverError.badResponse(status: 500, body: "bridge exception")
        guard case .badResponse(let status, let body)? =
                AndroidDriver.pressEnterAbort(after: original) else {
            return XCTFail("素通しした")
        }
        XCTAssertEqual(status, 500)
        XCTAssertEqual(body, "bridge exception")
    }

    /// **接頭辞はブリッジ(InputInjector.java)と同期**。文言は英語化などで変わるので、
    /// 判定は接頭辞で行う契約。ここが割れると no-focus が救えないほうへ倒れる
    func testMarkerMatchesTheBridgeSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let java = try String(contentsOf: root
            .appendingPathComponent("AndroidRunner/src/com/example/ftbridge/InputInjector.java"),
            encoding: .utf8)
        XCTAssertTrue(java.contains("\"\(AndroidDriver.noInputFocusMarker)"),
                      "InputInjector.java に接頭辞 \(AndroidDriver.noInputFocusMarker) が無い")
    }
}
