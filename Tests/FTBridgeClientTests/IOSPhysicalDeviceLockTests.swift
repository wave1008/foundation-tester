// `devicectl device info lockState` の読み取り。**現物の JSON で固定する**
// (2026-08-27 に iPhone SE3 / Xcode 27 beta6 で実測した2形。devicectl 642.15)。
// 見落とし(unknown)は許すが、**解除済みを locked と誤る側には倒さない**

import Foundation
import XCTest
@testable import FTBridgeClient

final class IOSPhysicalDeviceLockTests: XCTestCase {

    private func json(passcodeRequired: Bool) -> Data {
        Data("""
        {"info":{"commandType":"devicectl.device.info.lockState","jsonVersion":5,
                 "outcome":"success","version":"642.15"},
         "result":{"deviceIdentifier":"9D3C226E-EE5B-501D-9575-6636BD89314B",
                   "passcodeRequired":\(passcodeRequired),"unlockedSinceBoot":true}}
        """.utf8)
    }

    func testLockedWhenPasscodeIsRequiredNow() {
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(json(passcodeRequired: true)), .locked)
    }

    func testUnlockedWhenNoPasscodeIsRequired() {
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(json(passcodeRequired: false)), .unlocked)
    }

    /// `unlockedSinceBoot`(起動以降に一度でも解除したか=データ保護)を掴んでいないこと。
    /// これは**画面ロックの現況ではない**ので、ロック中でも true のままになる
    func testIgnoresUnlockedSinceBoot() {
        let data = Data("""
        {"result":{"unlockedSinceBoot":true}}
        """.utf8)
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(data), .unknown,
                       "passcodeRequired が無い応答を解除済みと読んではいけない")
    }

    /// 形式が変わった・devicectl が失敗した場合は unknown(促さない)
    func testMalformedIsUnknown() {
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(Data("not json".utf8)), .unknown)
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(Data("{}".utf8)), .unknown)
        XCTAssertEqual(IOSPhysicalDeviceLock.parse(
            Data(#"{"result":{"passcodeRequired":"true"}}"#.utf8)), .unknown,
                       "文字列の \"true\" を真と読まないこと")
    }
}
