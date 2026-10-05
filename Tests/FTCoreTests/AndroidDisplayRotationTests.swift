// `dumpsys window displays` から前面の要求する向きと表示の回転を読み、回転の指示が宣言で断られるかを決める
// (`AndroidDisplayRotation`)。AndroidDriver.rotate は宣言が回れないときだけ即座に断り、回れるときは
// 画面が追いつくのを待つ(固定の 5 秒で「遅い」と「回れない」を区別していた負荷下の誤った赤 → maintainer-notes §68.2)

import XCTest
@testable import FTCore

final class AndroidDisplayRotationTests: XCTestCase {
    /// Pixel 9 emulator(Android 15)でランチャーが前面のときの断片
    private let launcherDump = """
    WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
      Display: mDisplayId=0 (organized)
        init=1080x2424 420dpi cur=1080x2424 app=1080x2424
        overrideConfig={1.0 winConfig={ mDisplayRotation=ROTATION_0 mRotation=ROTATION_0} as.3}
        mLastOrientation=5
        mRotation=0 mDeferredRotationPauseCount=0
        mLandscapeRotation=ROTATION_90 mSeascapeRotation=ROTATION_270
    """

    /// Pixel 3a(Android 12)。構成のダンプ(`mRotation=ROTATION_0`)が Display 見出しより前に出る
    private let pixel3aRotatedDump = """
      overrideConfig={1.0 winConfig={ mBounds=Rect(0, 0 - 1080, 2220) mRotation=ROTATION_0} as.2}
      Display: mDisplayId=0 rootTasks=5
        mLastOrientation=-1
        mRotation=1 mDeferredRotationPauseCount=0
      Display: mDisplayId=2 rootTasks=1
        mLastOrientation=1
        mRotation=0 mDeferredRotationPauseCount=0
    """

    func testParsesTheFirstDisplayOnly() {
        XCTAssertEqual(AndroidDisplayRotation.parse(launcherDump),
                       .init(requestedOrientation: 5, rotation: 0))
        XCTAssertEqual(AndroidDisplayRotation.parse(pixel3aRotatedDump),
                       .init(requestedOrientation: -1, rotation: 1))
    }

    /// 1枚目に欄が無ければ不明のまま(2枚目の値で埋めない)
    func testDoesNotBorrowFromTheSecondDisplay() {
        let dump = """
          Display: mDisplayId=0 rootTasks=5
            init=1080x2424 420dpi
          Display: mDisplayId=2 rootTasks=1
            mLastOrientation=1
            mRotation=0 mDeferredRotationPauseCount=0
        """
        XCTAssertEqual(AndroidDisplayRotation.parse(dump), .init(requestedOrientation: nil, rotation: nil))
    }

    func testUnreadableDumpIsUnknown() {
        XCTAssertEqual(AndroidDisplayRotation.parse("Error: no such service"),
                       .init(requestedOrientation: nil, rotation: nil))
    }

    /// ランチャー(nosensor)は表示が目標でない限り断る。目標に居れば断らない
    func testNosensorRefusesWhileTheDisplayIsElsewhere() {
        XCTAssertNotNil(AndroidDisplayRotation.refusal(requestedOrientation: 5, rotation: 0, wantsLandscape: true))
        XCTAssertNil(AndroidDisplayRotation.refusal(requestedOrientation: 5, rotation: 1, wantsLandscape: true))
        XCTAssertNil(AndroidDisplayRotation.refusal(requestedOrientation: 14, rotation: nil, wantsLandscape: true),
                     "表示の回転が読めないときは断らない")
    }

    func testFixedOrientationsRefuseTheOtherOne() {
        for portraitOnly in [1, 7, 9, 12] {
            XCTAssertNotNil(AndroidDisplayRotation.refusal(requestedOrientation: portraitOnly, rotation: 0,
                                                           wantsLandscape: true), "\(portraitOnly)")
            XCTAssertNil(AndroidDisplayRotation.refusal(requestedOrientation: portraitOnly, rotation: 0,
                                                        wantsLandscape: false), "\(portraitOnly)")
        }
        for landscapeOnly in [0, 6, 8, 11] {
            XCTAssertNotNil(AndroidDisplayRotation.refusal(requestedOrientation: landscapeOnly, rotation: 1,
                                                           wantsLandscape: false), "\(landscapeOnly)")
            XCTAssertNil(AndroidDisplayRotation.refusal(requestedOrientation: landscapeOnly, rotation: 1,
                                                        wantsLandscape: true), "\(landscapeOnly)")
        }
    }

    /// 回れる宣言(未指定・sensor・user 等)は断らない = 待つ側
    func testRotatableDeclarationsNeverRefuse() {
        for rotatable in [-1, 2, 3, 4, 10, 13] {
            for rotation in [0, 1] {
                for wantsLandscape in [true, false] {
                    XCTAssertNil(AndroidDisplayRotation.refusal(requestedOrientation: rotatable, rotation: rotation,
                                                                wantsLandscape: wantsLandscape),
                                 "\(rotatable) rotation=\(rotation) landscape=\(wantsLandscape)")
                }
            }
        }
    }
}
