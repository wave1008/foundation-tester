// ScaleGestureDetector の最小スケール距離 = 27 mm を density から px に換算する(§19 M5)

import XCTest
@testable import FTAndroid

final class AndroidMinimumScalingSpanTests: XCTestCase {
    func testTwentySevenMillimetresAtPixel3aDensity() {
        // 440 dpi = 2.75 px/dp → 27 / 25.4 × 440 = 467.7 px
        XCTAssertEqual(AndroidDriver.minimumScalingSpanPx(densityPxPerDp: 2.75), 467.7, accuracy: 0.1)
        // 160 dpi(1 px/dp)なら 170 px
        XCTAssertEqual(AndroidDriver.minimumScalingSpanPx(densityPxPerDp: 1), 170.1, accuracy: 0.1)
    }
}
