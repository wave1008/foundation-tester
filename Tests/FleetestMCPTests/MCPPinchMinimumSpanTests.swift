// Android の座標ピンチの既定半径は、指の最大間隔が最小スケール距離(27 mm)を超えるように広げる
// (§19 M5: Pixel 3a で既定 238 px = 間隔 428 px が 468 px を下回り、一切ズームしなかった)。
// 判定は純関数 `MCPServer.pinchRadiusHonouringMinimumSpan` に置く(AndroidDriver は FakeDriver から模せない)

import XCTest
@testable import fleetest_mcp

final class MCPPinchMinimumSpanTests: XCTestCase {
    /// 468 px(440 dpi)の最小距離に対し、既定 238 px は 325 px(= 468 × 1.25 / 1.8 の切り上げ)へ
    func testDefaultRadiusIsWidenedToExceedTheMinimumSpan() {
        let widened = MCPServer.pinchRadiusHonouringMinimumSpan(defaultRadius: 238, minimumSpan: 468)
        XCTAssertEqual(widened, 325)
        // ブリッジの最大間隔(短辺 × 0.9)が最小距離を 25% 超える
        XCTAssertGreaterThanOrEqual(widened * 2 * 0.9, 468 * 1.25)
    }

    /// 既定が既に足りていれば触らない・最小距離が読めなければ既定のまま
    func testLargeDefaultAndUnknownSpanAreLeftAlone() {
        XCTAssertEqual(MCPServer.pinchRadiusHonouringMinimumSpan(defaultRadius: 400, minimumSpan: 468), 400)
        XCTAssertEqual(MCPServer.pinchRadiusHonouringMinimumSpan(defaultRadius: 238, minimumSpan: nil), 238)
        XCTAssertEqual(MCPServer.pinchRadiusHonouringMinimumSpan(defaultRadius: 238, minimumSpan: 0), 238)
    }

    /// 配線: 明示の radius には触らず、Android だけが広げる(ソース走査)
    func testOnlyAndroidWidensAndExplicitRadiusWins() throws {
        let code = try MCPServerSourceText.combined()
        XCTAssertTrue(code.contains("if pinchRadius == nil, let android = pinchDriver as? AndroidDriver,"),
                      "Android 限定・明示 radius 優先の条件が消えている")
        XCTAssertTrue(code.contains("let minimumSpan = android.minimumScalingSpanPx()"), "最小距離を端末から採っていない")
    }
}
