// `adb shell dumpsys activity service com.android.systemui/.SystemUIService` の実測(Pixel 9・
// Android 15 エミュレータ)を固定する。swipeBy が back を奪う帯を避けるための唯一の入力元

import XCTest
@testable import FTCore

final class AndroidBackGestureEdgesTests: XCTestCase {

    /// 実測スニペット(前後の無関係な行を含む。ブロックの終端はインデントの浅い次の行)
    private static let gestureNavSnippet = """
          EdgeBackGestureHandler:
            mIsBackGestureAllowed=true
            mIsGestureHandlingEnabled=true
            mEdgeWidthLeft=78
            mEdgeWidthRight=78
          mLastReportedConfig=
        """

    private static let threeButtonNavSnippet = """
          EdgeBackGestureHandler:
            mIsBackGestureAllowed=true
            mIsGestureHandlingEnabled=false
            mEdgeWidthLeft=78
            mEdgeWidthRight=78
          mLastReportedConfig=
        """

    func testParsesTheRealGestureNavigationSnippet() {
        let widths = AndroidBackGestureEdges.parse(Self.gestureNavSnippet)
        XCTAssertEqual(widths?.left, 78)
        XCTAssertEqual(widths?.right, 78)
    }

    /// 3ボタン navigation は帯そのものが無効 = 除外不要(実測 0 ではなく仕様として (0, 0))
    func testThreeButtonNavigationReturnsZeroZero() {
        let widths = AndroidBackGestureEdges.parse(Self.threeButtonNavSnippet)
        XCTAssertEqual(widths?.left, 0)
        XCTAssertEqual(widths?.right, 0)
    }

    /// ブロックが無い/鍵が読めない出力は nil(呼び手は除外しない側に倒す)
    func testUnparseableOutputReturnsNil() {
        XCTAssertNil(AndroidBackGestureEdges.parse("garbage\nnot a dumpsys at all\n"))
        XCTAssertNil(AndroidBackGestureEdges.parse(""))
    }

    /// mIsGestureHandlingEnabled 自体が読めない(欄が欠けている)ときも nil
    func testMissingEnabledKeyReturnsNil() {
        let snippet = """
              EdgeBackGestureHandler:
                mIsBackGestureAllowed=true
                mEdgeWidthLeft=78
                mEdgeWidthRight=78
            """
        XCTAssertNil(AndroidBackGestureEdges.parse(snippet))
    }

    /// enabled かつ幅が読めなければ nil(bool は読めても数値が壊れている形)
    func testEnabledWithUnreadableWidthsReturnsNil() {
        let snippet = """
              EdgeBackGestureHandler:
                mIsGestureHandlingEnabled=true
                mEdgeWidthLeft=notanumber
                mEdgeWidthRight=78
            """
        XCTAssertNil(AndroidBackGestureEdges.parse(snippet))
    }

    /// dumpsys はセクションを複数回吐きうる。**最初のブロックの値を一貫して採る**
    func testRepeatedBlocksPickTheFirstOccurrenceConsistently() {
        let snippet = """
              EdgeBackGestureHandler:
                mIsGestureHandlingEnabled=true
                mEdgeWidthLeft=78
                mEdgeWidthRight=78
              EdgeBackGestureHandler:
                mIsGestureHandlingEnabled=true
                mEdgeWidthLeft=999
                mEdgeWidthRight=999
            """
        let widths = AndroidBackGestureEdges.parse(snippet)
        XCTAssertEqual(widths?.left, 78)
        XCTAssertEqual(widths?.right, 78)
    }
}
