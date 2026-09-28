// `adb shell dumpsys window` から Android のジェスチャナビゲーションバーを読む純粋パーサの固定。
import XCTest
@testable import FTCore

final class AndroidSystemBarsTests: XCTestCase {

    /// 実機で観測した dumpsys の抜粋(実機実測: gesture navigation・1080x2424)
    private static let realExcerpt = """
            InsetsSource id=b3420001 type=navigationBars frame=[0,2361][1080,2424] visible=true flags=SUPPRESS_SCRIM|ANIMATE_RESIZING sideHint=BOTTOM boundingRects=null
            InsetsSource id=b3420004 type=systemGestures frame=[0,0][78,2424] visible=true flags= sideHint=LEFT boundingRects=null
            InsetsSource id=b3420005 type=mandatorySystemGestures frame=[0,2340][1080,2424] visible=true flags= sideHint=BOTTOM boundingRects=null
            InsetsSource id=b3420024 type=systemGestures frame=[1002,0][1080,2424] visible=true flags= sideHint=RIGHT boundingRects=null
            InsetsSource id=ec5f0005 type=mandatorySystemGestures frame=[0,0][1080,174] visible=true flags= sideHint=TOP boundingRects=null
        """

    func testParsesTheRealExcerpt() {
        let bar = AndroidSystemBars.bottomNavigationBar(Self.realExcerpt)
        XCTAssertEqual(bar, FTRect(x: 0, y: 2361, width: 1080, height: 63))
    }

    func testNoNavigationBarsLineMeansNil() {
        let dumpsys = """
                InsetsSource id=b3420004 type=systemGestures frame=[0,0][78,2424] visible=true flags= sideHint=LEFT boundingRects=null
            """
        XCTAssertNil(AndroidSystemBars.bottomNavigationBar(dumpsys))
    }

    func testInvisibleNavigationBarIsNotACover() {
        let dumpsys = """
                InsetsSource id=b3420001 type=navigationBars frame=[0,2361][1080,2424] visible=false flags= sideHint=BOTTOM boundingRects=null
            """
        XCTAssertNil(AndroidSystemBars.bottomNavigationBar(dumpsys))
    }

    func testMalformedFrameIsNil() {
        let dumpsys = """
                InsetsSource id=b3420001 type=navigationBars frame=[abc,2361][1080,2424] visible=true flags= sideHint=BOTTOM boundingRects=null
            """
        XCTAssertNil(AndroidSystemBars.bottomNavigationBar(dumpsys))
    }

    /// 上端の navigationBars(タブレットの分割・ステータスバー側の申告等)は対象外
    func testTopSideNavigationBarIsIgnored() {
        let dumpsys = """
                InsetsSource id=ec5f0001 type=navigationBars frame=[0,0][1080,174] visible=true flags= sideHint=TOP boundingRects=null
            """
        XCTAssertNil(AndroidSystemBars.bottomNavigationBar(dumpsys))
    }

    /// 3ボタン navigation は同じ型でより高い矩形を申告する(実測想定値)
    func testThreeButtonNavigationStyleFrame() {
        let dumpsys = """
                InsetsSource id=b3420001 type=navigationBars frame=[0,2298][1080,2424] visible=true flags= sideHint=BOTTOM boundingRects=null
            """
        let bar = AndroidSystemBars.bottomNavigationBar(dumpsys)
        XCTAssertEqual(bar?.height, 126)
    }
}
