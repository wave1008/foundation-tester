// MCP の `ft_rotate portrait` の後に端末の回転設定を戻すかの判定(§19 R1)。
// 元から向きが固定されていた端末(前の MCP セッションが横のまま切れた後)で元の user_rotation を
// 書き戻すと、明示された portrait を横へ取り消しながら「Rotated to portrait」と答えていた(Pixel 3a)。
// 判定は `AndroidDriver.autoRotateRestorePlan` の1箇所(adb 無しで固める)

import XCTest
@testable import FTAndroid

final class AndroidRotationRestoreTests: XCTestCase {
    /// 元が auto-rotate(accelerometer_rotation=1)なら端末の設定へ返す
    func testAutoRotateOriginalIsRestored() {
        XCTAssertEqual(AndroidDriver.autoRotateRestorePlan(original: (userRotation: 0, accelerometerRotation: 1)),
                       .restored)
        XCTAssertEqual(AndroidDriver.autoRotateRestorePlan(original: (userRotation: 1, accelerometerRotation: 1)),
                       .restored)
    }

    /// 元から固定(accelerometer_rotation=0)なら、要求された向きの固定をそのまま残す ——
    /// 元の user_rotation が横(1 / 3)でも縦(0 / 2)でも書き戻さない(縦固定の書き戻しは無害だが、
    /// 「固定されていた端末は要求された向きに固定したまま」の1規則にしておく)
    func testLockedOriginalKeepsTheExplicitPortrait() {
        for userRotation in 0...3 {
            XCTAssertEqual(AndroidDriver.autoRotateRestorePlan(
                original: (userRotation: userRotation, accelerometerRotation: 0)),
                .keptExplicitLock, "user_rotation=\(userRotation)")
        }
    }

    /// rotate(to:) を一度も呼んでいなければ何もしない
    func testNoRecordMeansNothingToRestore() {
        XCTAssertEqual(AndroidDriver.autoRotateRestorePlan(original: nil), .nothingToRestore)
    }
}
