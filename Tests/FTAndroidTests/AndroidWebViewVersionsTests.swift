// フリート内の WebView 版の混在検知(`AndroidWebViewVersions`。2026-08-14)。
//
// 実測の背景: **WebView 124 は WebView 内の `#id` を1つも出さず、150 は出す**。
// 混在すると同じシナリオが端末によって落ちる。

import XCTest
@testable import FTAndroid

final class AndroidWebViewVersionsTests: XCTestCase {

    /// dumpsys は `versionName=` を複数回出す。**先頭に固定**しないと端末間で違う行を拾って
    /// 「混在している」と誤報する
    func testTakesTheFirstVersionName() {
        let dumpsys = """
          Package [com.google.android.webview]
            versionName=124.0.6367.219
            signatures=...
            versionName=999.0.0.0
        """
        XCTAssertEqual(AndroidWebViewVersions.versionName(inDumpsys: dumpsys), "124.0.6367.219")
    }

    func testNoVersionNameYieldsNil() {
        XCTAssertNil(AndroidWebViewVersions.versionName(inDumpsys: "Unable to find package"))
    }

    /// **実測した組み合わせそのもの**(エミュレータ 124 / 実機 150)
    func testWarnsWhenMajorVersionsDiffer() throws {
        let warning = try XCTUnwrap(AndroidWebViewVersions.mixedVersionWarning(
            ["emulator-5554": "150.0.7871.181", "emulator-5556": "124.0.6367.219"]))
        XCTAssertTrue(warning.contains("124"), warning)
        XCTAssertTrue(warning.contains("150"), warning)
        XCTAssertTrue(warning.contains("#id"), "何が起きるかまで言うこと")
        XCTAssertTrue(warning.contains("placeholder"), "入れ替わる相手も言うこと(片方だけだと誤解する)")
    }

    /// **パッチ違いでは言わない** —— 毎回出ると読み飛ばされる
    func testSamePatchFamilyIsNotAWarning() {
        XCTAssertNil(AndroidWebViewVersions.mixedVersionWarning(
            ["a": "124.0.6367.219", "b": "124.0.6367.100"]))
    }

    func testSingleDeviceIsNeverMixed() {
        XCTAssertNil(AndroidWebViewVersions.mixedVersionWarning(["a": "124.0.6367.219"]))
        XCTAssertNil(AndroidWebViewVersions.mixedVersionWarning([:]))
    }

    /// 取れない端末は落とす(判定材料が無いだけで異常ではない)
    func testDevicesWithoutAVersionAreSkipped() {
        let versions = AndroidWebViewVersions.collect(serials: ["a", "b"]) { serial, _ in
            serial == "a" ? "versionName=124.0.6367.219" : nil
        }
        XCTAssertEqual(versions, ["a": "124.0.6367.219"])
    }
}
